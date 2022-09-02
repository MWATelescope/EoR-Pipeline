#!/usr/bin/env nextflow
nextflow.enable.dsl=2

// download observation metadata from webservices in json format
process wsMeta {
    input:
    val(obsid)
    output:
    tuple val(obsid), path ("${obsid}_wsmeta.json")

    // persist results in outdir, process will be skipped if files already present.
    storeDir "${params.outdir}/meta"
    // tag to identify job in squeue and nf logs
    tag "${obsid}"

    script:
    """
    #!/bin/bash
    ${params.proxy_prelude} # ensure proxy is set if needed
    wget -O ${obsid}_wsmeta.json "http://ws.mwatelescope.org/metadata/obs?obs_id=${obsid}&extended=1&dict=1"
    """
}

// Ensure the raw visibility files are present, or download via ASVO
process asvoRaw {
    input:
    val obsid
    output:
    tuple val(obsid), path("${obsid}.metafits"), path("${obsid}_2*.fits")

    storeDir "${params.outdir}/$obsid/raw"
    // tag to identify job in squeue and nf logs
    tag "${obsid}"

    // allow multiple retries
    maxRetries 5
    // exponential backoff: sleep for 2^attempt hours after each fail
    errorStrategy {
        failure_reason = [
            5: "I/O error or hash mitch",
            28: "No space left on device",
        ][task.exitStatus]
        if (failure_reason) {
            println "task ${task.hash} failed with code ${task.exitStatus}: ${failure_reason}"
            return 'ignore'
        }
        retry_reason = [
            1: "general or permission",
            11: "Resource temporarily unavailable",
            75: "Temporary failure, try again"
        ][task.exitStatus] ?: "unknown"
        wait_hours = Math.pow(2, task.attempt)
        println "sleeping for ${wait_hours} hours and retrying task ${task.hash}, which failed with code ${task.exitStatus}: ${retry_reason}"
        sleep(wait_hours * 60*60*1000 as long)
        return 'retry'
    }

    script:
    """
    # echo commands, exit on any failures
    set -eux
    export MWA_ASVO_API_KEY="${params.asvo_api_key}"

    ${params.proxy_prelude} # ensure proxy is set if needed

    function ensure_disk_space {
        local needed=\$1
        if read -r avail < <(df --output=avail . | tail -n 1); then
            avail_bytes=\$((\$avail * 1000))
            if [[ \$avail_bytes -lt \$needed ]]; then
                echo "Not enough disk space available in \$PWD, need \$needed B, have \$avail_bytes B"
                exit 28  # No space left on device
            fi
            return 0
        fi
        echo "Could not determine disk space in \$PWD"
        exit 28
    }

    # submit a job to ASVO, suppress failure if a job already exists.
    ${params.giant_squid} submit-vis --delivery "acacia" $obsid || true

    # extract id and state from pending download vis jobs
    ${params.giant_squid} list -j --types download_visibilities --states queued,processing,error -- $obsid \
        | ${params.jq} -r '.[]|[.jobId,.jobState]|@tsv' \
        | tee pending.tsv

    # extract id url size hash from any ready download vis jobs for this obsid
    ${params.giant_squid} list -j --types download_visibilities --states ready -- $obsid \
        | tee /dev/stderr \
        | ${params.jq} -r '.[]|[.jobId,.files[0].fileUrl//"",.files[0].fileSize//"",.files[0].fileHash//""]|@tsv' \
        | tee ready.tsv

    # download the first ready jobs
    if read -r jobid url size hash < ready.tsv; then
        ensure_disk_space "\$size" || exit \$?
        # wget into two pipes:
        # - first pipe untars the archive to disk
        # - second pipe validates the sha sum
        wget \$url -O- --progress=dot:giga --wait=60 --random-wait \
            | tee >(tar -x) \
            | sha1sum -c <(echo "\$hash -")
        ps=("\${PIPESTATUS[@]}")
        if [ \${ps[0]} -ne 0 ]; then
            echo "Download failed. status=\${ps[0]}"
            exit \${ps[0]}
        elif [ \${ps[1]} -ne 0 ]; then
            echo "Untar failed. status=\${ps[1]}"
            exit \${ps[1]}
        elif [ \${ps[2]} -ne 0 ]; then
            echo "Hash check failed. status=\${ps[2]}"
            exit \${ps[2]}
        fi
        exit 0 # success
    fi
    echo "no ready jobs"
    exit 75 # temporary
    """
}

// extract relevant info from metafits into json
process metaJson {
    input:
    tuple val(obsid), path("${obsid}.metafits")
    output:
    tuple val(obsid), path("${obsid}.metafits.json")

    scratch false
    storeDir "${params.outdir}/${obsid}/raw"

    tag "${obsid}"

    module 'python/3.9.7'
    // TODO: try this:
    // module "miniconda/4.8.3"
    // conda "${params.astro_conda}"

    script:
    """
    #!/usr/bin/env python

    from astropy.io import fits
    from json import dump as json_dump
    from collections import OrderedDict

    with \
        open('${obsid}.metafits.json', 'w') as out, \
        fits.open("${obsid}.metafits") as hdus \
    :
        data = OrderedDict()
        for key in hdus['PRIMARY'].header:
            if type(hdus['PRIMARY'].header[key]) not in [bool, int, str, float]:
                continue
            data[key] = hdus['PRIMARY'].header[key]
            if key in [ 'RECVRS', 'DELAYS', 'CHANNELS', 'CHANSEL' ]:
                data[key] = [*filter(None, map(lambda t: t.strip(), data[key].split(',')))]

        data['FLAGGED_INPUTS'] = [
            r['TileName'] + r['Pol']
            for r in hdus['TILEDATA'].data
            if r['Flag'] == 1
        ]

        data['DELAYS'] = hdus['TILEDATA'].data['Delays'].tolist()

        json_dump(data, out, indent=4)
    """
}

// Ensure preprocessed observation is present, or preprocess raw with Birli
process birliPrep {
    input:
    tuple val(obsid), val(spw), path("${obsid}.metafits"), path("*") // <-preserves names of fits files
    output:
    tuple val(obsid), val(spw), path("birli_${obsid}${spw}.uvfits"), path("${obsid}${spw}*.mwaf"), path("birli_prep.log")

    storeDir "${params.outdir}/${obsid}/prep"

    tag "${obsid}${spw}"
    // label jobs that need a bigger cpu allocation
    label "cpu"

    // birli runs in singularity
    module "singularity"

    script:
    flag_template = obsid as int > 1300000000 ? "${obsid}${spw}_ch%%%.mwaf" : "${obsid}${spw}_%%.mwaf"
    """
    set -eux
    ${params.birli} \
        -u "birli_${obsid}${spw}.uvfits" \
        -f "${flag_template}" \
        -m "${obsid}.metafits" \
        --avg-time-res ${params.prep_time_res_s} \
        --avg-freq-res ${params.prep_freq_res_khz} \
        ${obsid}*.fits 2>&1 | tee birli_prep.log
    if [ ! -f "birli_${obsid}${spw}.uvfits" ]; then
        echo "no uvfits produced, birli failed silently"
        exit 1
    fi
    """
}

// Simple check for vis, to catch "past end of file" errors
process prepStats {
    input:
    tuple val(obsid), path("birli_${obsid}.uvfits")
    output:
    tuple val(obsid), path("${obsid}_prep_stats.json")

    scratch false
    storeDir "${params.outdir}/${obsid}/prep"

    tag "${obsid}"

    module 'python/3.9.7'
    // TODO: try this:
    // module "miniconda/4.8.3"
    // conda "${params.astro_conda}"

    script:
    """
    #!/usr/bin/env python

    from astropy.io import fits
    from json import dump as json_dump
    from collections import OrderedDict

    with \
        open('${obsid}_prep_stats.json', 'w') as out, \
        fits.open("birli_${obsid}.uvfits") as hdus \
    :
        data = OrderedDict()
        first_shape=hdus[0].data[0].data.shape
        data['num_chans']=first_shape[2]
        all_times=hdus[0].data['DATE']
        data['num_times']=len(set(all_times))
        data['num_baselines']=len(all_times)//data['num_times']

        json_dump(data, out, indent=4)
    """
}

// QA tasks for flags.
process flagQA {
    input:
    tuple val(obsid), path("${obsid}.metafits"), path("*") // <-preserves names of mwaf files
    output:
    tuple val(obsid), path("${obsid}_occupancy.json")

    storeDir "${params.outdir}/${obsid}/prep"

    tag "${obsid}"

    module 'python/3.9.7'
    // module "miniconda/4.8.3"
    // conda "${params.astro_conda}"

    script:
    """
    #!/usr/bin/env python

    from astropy.io import fits
    from json import dump as json_dump
    from glob import glob
    from os.path import basename
    import numpy as np
    import re

    RE_MWAX_NAME = (
        r"\\S+_ch(?P<rec_chan>\\d{3}).mwaf"
    )
    RE_MWA_LGCY_NAME = (
        r"\\S+_(?P<gpubox_num>\\d{2}).mwaf"
    )

    def parse_filename(name, metafits_coarse_chans):
        result = {}
        if match:=re.match(RE_MWAX_NAME, name):
            result.update({
                'type': 'mwax',
                'rec_chan': int(match.group('rec_chan')),
            })
            result['gpubox_num'] = int(metafits_coarse_chans.index(result['rec_chan']))
        elif match:=re.match(RE_MWA_LGCY_NAME, name):
            result.update({
                'type': 'legacy',
                'gpubox_num': int(match.group('gpubox_num')),
            })
            result['rec_chan'] = int(metafits_coarse_chans[result['gpubox_num']-1])
        return result

    def split_strip_filter(str):
        return list(filter(None, map(lambda tok: tok.strip(), str.split(','))))

    paths = sorted(glob("*.mwaf"))
    total_occupancy = 0
    total_non_preflagged_bl_occupancy = 0
    num_coarse_chans = len(paths)
    num_non_preflagged_chans = 0
    with \
        open('${obsid}_occupancy.json', 'w') as out, \
        fits.open("${obsid}.metafits") as meta \
    :
        data = {'obsid': ${obsid}, 'channels': {}}
        t = meta['TILEDATA'].data
        preflagged_ants = np.unique(t[t['Flag'] > 0]['Antenna'])
        data['preflagged_ants'] = preflagged_ants.tolist()
        metafits_coarse_chans = [*map(int, split_strip_filter(meta[0].header['CHANNELS']))]
        for path in paths:
            filename_info = parse_filename(path, metafits_coarse_chans)
            if not data.get('type'):
                data['type'] = filename_info.get('type', '???')
            chan_id = filename_info.get('rec_chan', basename(path))
            data['channels'][chan_id] = {}
            with fits.open(path) as hdus:
                flag_data = hdus['FLAGS'].data['FLAGS']
                occupancy = flag_data.sum() / flag_data.size
                data['channels'][chan_id]['occupancy'] = occupancy
                total_occupancy += occupancy
                bls = hdus['BL_OCC'].data
                non_preflagged_bls = bls[~(np.isin(bls['Antenna1'],preflagged_ants)|np.isin(bls['Antenna2'],preflagged_ants))]
                non_preflagged_bl_count = non_preflagged_bls.shape[0]
                if non_preflagged_bl_count:
                    num_non_preflagged_chans += 1
                    non_preflagged_bl_occupancy = non_preflagged_bls['Occupancy'].sum() / non_preflagged_bls.shape[0]
                    data['channels'][chan_id]['non_preflagged_bl_occupancy'] = non_preflagged_bl_occupancy
                    total_non_preflagged_bl_occupancy += non_preflagged_bl_occupancy
        if num_coarse_chans:
            total_occupancy /= num_coarse_chans
        data['total_occupancy'] = total_occupancy
        if num_non_preflagged_chans:
            total_non_preflagged_bl_occupancy /= num_non_preflagged_chans
        data['total_non_preflagged_bl_occupancy'] = total_non_preflagged_bl_occupancy
        json_dump(data, out, indent=4)
    """
}

def groovy2bashAssocArray(map, name) {
    // size = map.collect { _, v -> v.size() }.max()
    "declare -A ${name}=(" + map.collect { k, v -> "[${k}]=\"${v}\"".toString() }.join(" ") + ")".toString()
}

// // ensure calibration solutions are present, or calibrate prep with hyperdrive
// // do multiple calibration solutions for each obs
// process hypCalSolMux {
//     input:
//     tuple val(obsids), val(dical_names), val(dical_args), path("*"), path("*") // metafits, uvfits
//     output:
//     tuple val(obsids), val(dical_names), path("hyp_soln_${name_glob}.fits"), path("hyp_model_${name_glob}.uvfits"), path("hyp_di-cal_${name_glob}.log")

//     storeDir "${params.outdir}/cal_tmp/"

//     // label jobs that need a bigger gpu allocation
//     label "gpu"

//

//     module "cuda/11.3.1:gcc-rt/9.2.0"

//     afterScript "ls ${task.storeDir}"

//     script:
//     obs_cals = [obsids, dical_names].transpose().collect { it.join("_") }
//     name_glob = "{" + obs_cals.join(',') + "}"
//     """
//     # use this control which GPU we're sending the job to
//     export CUDA_VISIBLE_DEVICES=0

//     set -eux
//     export num_gpus="\$(nvidia-smi -L | wc -l)"
//     if [ \$num_gpus -eq 0 ]; then
//         echo "no gpus found"
//         exit 1
//     fi
//     if [ \$num_gpus -ne ${params.num_gpus} ]; then
//         echo "warning: expected \$num_gpus to be ${params.num_gpus}"
//     fi
//     ${groovy2bashAssocArray(dical_args, "dical_args")}
//     task_obsids=(${obsids.join(' ')})
//     task_dical_names=(${dical_names.join(' ')})
//     if [ \${#task_obsids[@]} -ne \${#task_dical_names[@]} ]; then
//         echo "number of obsids (\${#task_obsids[@]}) doesn't match number of dical names (\${#task_dical_names[@]})"
//         exit 1
//     fi
//     export n_tasks="\${#task_obsids[@]}"
//     if [ \$n_tasks -eq 0 ]; then
//         echo "no tasks to do"
//         exit 0
//     fi
//     if [ \$n_tasks -gt \$num_gpus ]; then
//         echo "warning: more tasks than gpus";
//     fi
//     for task in \$(seq 0 \$((n_tasks-1))); do
//         obsid=\${task_obsids[\$task]}
//         name=\${task_dical_names[\$task]}
//         args=\${dical_args[\$name]}
//         # on first iteration, this does nothing. on nth, wait for all background jobs to finish
//         # if [[ \$CUDA_VISIBLE_DEVICES -eq 0 ]]; then
//         #     wait \$(jobs -rp)
//         # fi
//         # hyperdrive di-cal backgrounded in a subshell
//         (
//             ${params.hyperdrive} di-calibrate \${args} \
//                 --data "\${obsid}.metafits" *\${obsid}*.uvfits \
//                 --beam "${params.beam_path}" \
//                 --source-list "${params.sourcelist}" \
//                 --outputs "hyp_soln_\${obsid}_\${name}.fits" \
//                 --model-filenames "hyp_model_\${obsid}_\${name}.uvfits" \
//                 > "hyp_di-cal_\${obsid}_\${name}.log"
//         ) &
//         # increment the target device mod num_gpus
//         CUDA_VISIBLE_DEVICES=\$(( CUDA_VISIBLE_DEVICES+1 % \${num_gpus} ))
//     done

//     # wait for all the background jobs to finish
//     export result=0
//     wait \$(jobs -rp) || result=\$?

//     # print out important info from log
//     if [ \$(ls *.log 2> /dev/null | wc -l) -gt 0 ]; then
//         grep -iE "err|warn|hyperdrive|chanblocks|reading|writing|flagged" *.log
//     fi

//     exit \$result
//     """
// }

// ensure calibration solutions are present, or calibrate prep with hyperdrive
// do multiple calibration solutions for each obs, depending on dical_args
process hypCalSol {
    input:
    tuple val(obsid), val(dical_args), path("${obsid}.metafits"), path("${obsid}.uvfits") // metafits, uvfits
    output:
    tuple val(obsid), path("hyp_soln_${obsid}_${name_glob}.fits"), path("hyp_di-cal_${obsid}_${name_glob}.log")
    // todo: model subtract: path("hyp_model_${obsid}_${name_glob}.uvfits")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"

    tag "${obsid}"

    // label jobs that need a bigger gpu allocation
    label "gpu"

    module "cuda/11.3.1:gcc-rt/9.2.0"

    afterScript "ls ${task.storeDir}"

    script:
    dical_names = dical_args.keySet().collect()
    para = dical_names.size() > 1
    name_glob = para ? "{" + dical_names.join(',') + "}" : dical_names[0]
    """
    set -eux
    ${para ? "export CUDA_VISIBLE_DEVICES=0" : ""}
    export num_gpus="\$(nvidia-smi -L | wc -l)"
    if [ \$num_gpus -eq 0 ]; then
        echo "no gpus found"
        exit 1
    fi
    if [ \$num_gpus -ne ${params.num_gpus} ]; then
        echo "warning: expected \$num_gpus to be ${params.num_gpus}"
    fi
    ${groovy2bashAssocArray(dical_args, "dical_args")}
    if [ \${#dical_args[@]} -eq 0 ]; then
        echo "no dical args"
        exit 0
    fi
    if [ \${#dical_args[@]} -gt \$num_gpus ]; then
        echo "warning: more dical args than gpus";
    fi
    for name in \${!dical_args[@]}; do
        args=\${dical_args[\$name]}
        # hyperdrive di-cal backgrounded in a subshell
        (
            ${params.hyperdrive} di-calibrate \${args} \
                --data "${obsid}.metafits" "${obsid}.uvfits" \
                --beam "${params.beam_path}" \
                --source-list "${params.sourcelist}" \
                --outputs "hyp_soln_${obsid}_\${name}.fits" \
                > "hyp_di-cal_${obsid}_\${name}.log"
        ) &
        # TODO: model subtract: --model-filenames "hyp_model_${obsid}_\${name}.uvfits"
        # increment the target device mod num_gpus
        ${para ? "CUDA_VISIBLE_DEVICES=\$(( CUDA_VISIBLE_DEVICES+1 % \${num_gpus} ))" : ""}
    done

    # wait for all the background jobs to finish
    export result=0
    wait \$(jobs -rp) || result=\$?

    # print out important info from log
    if [ \$(ls *.log 2> /dev/null | wc -l) -gt 0 ]; then
        grep -iE "err|warn|hyperdrive|chanblocks|reading|writing|flagged" *.log
    fi

    exit \$result
    """
}

// fit polynomial to calibration solution
process polyFit {
    input:
    tuple val(obsid), val(dical_name), path("hyp_soln_${obsid}_${dical_name}.fits")
    output:
    tuple val(obsid), val(name), path("hyp_soln_${obsid}_${name}.fits")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"
    tag "${obsid}.${dical_name}"

    module 'python/3.9.7'
    // TODO: try this:
    // module "miniconda/4.8.3"
    // conda "${params.astro_conda}"

    script:
    name = "poly_${dical_name}"
    """
    #!/usr/bin/env python
    # this is nextflow-ified version of /astro/mwaeor/ctrott/poly_fit.py
    # TODO: this deserves its own version control

    from astropy.io import fits
    import numpy as np
    from numpy.polynomial import Polynomial


    def get_unflagged_indices(n_bands, n_chan, clip_width=0):
        # Returns indices of unflagged frequency channels
        edge_flags = 2 + clip_width
        centre_flag = n_chan // 2

        channels = np.arange(n_chan)
        channels = np.delete(channels, centre_flag)
        channels = channels[edge_flags:-edge_flags]

        all_channels = []
        for n in range(n_bands):
            for c in channels:
                all_channels.append(c+(n*n_chan))
        return all_channels


    def fit_hyperdrive_sols(sols, results, order=3, clip_width=0):
        # Fits polynomial to real and imaginary part of hyperdrive solutions
        # Remove flagged channels
        # Hyperdrive solutions have dimensions ((time),ant,freq,pols)

        n_bands = 24
        n_ants, n_freqs, n_pols = np.shape(sols)
        assert n_freqs % n_bands == 0
        n_chan = n_freqs // n_bands

        models_out = np.zeros_like(sols, dtype=complex)

        clipped_x = get_unflagged_indices(n_bands, n_chan, clip_width=clip_width)
        # filter any channels where result is NaN
        clipped_x = [ x for x in clipped_x if not np.isnan(results[x]) ]

        # Remove flagged tiles which are nan at first unflagged frequency and pol
        good_tiles = np.argwhere(~np.isnan(sols[:, clipped_x[0], 0]))

        freq_array = np.arange(n_freqs)

        for ant in good_tiles:
            for pol in range(n_pols):
                z_r = Polynomial.fit(clipped_x, np.real(
                    sols[ant, clipped_x, pol]), deg=order)
                z_i = Polynomial.fit(clipped_x, np.imag(
                    sols[ant, clipped_x, pol]), deg=order)
                models_out[ant, :, pol] = z_r(freq_array) + z_i(freq_array) * 1j

        return models_out

    infile = "hyp_soln_${obsid}_${dical_name}.fits"
    outfile = "hyp_soln_${obsid}_${name}.fits"

    with fits.open(infile) as hdus:
        # Reads hyperdrive solutions from fits file into numpy array
        data = hdus["SOLUTIONS"].data
        for i_timeblock in range(data.shape[0]):
            sols = data[i_timeblock, :, :, ::2] + data[i_timeblock, :, :, 1::2] * 1j
            results = hdus["RESULTS"].data[i_timeblock,:]

            fit_sols = fit_hyperdrive_sols(sols, results)

            # Write fitted solutions
            hdus["SOLUTIONS"].data[i_timeblock, :, :, ::2] = np.real(fit_sols)
            hdus["SOLUTIONS"].data[i_timeblock, :, :, 1::2] = np.imag(fit_sols)

        hdus.writeto(outfile, overwrite="True")
    """
}

// ensure calibrated uvfits are present, or apply calsols to prep uvfits with hyperdrive
process hypApplyUV {
    input:
    tuple val(obsid), path("${obsid}.metafits"), path("${obsid}.uvfits"), path("hyp_soln_${obsid}_${cal_name}.fits"), \
        val(cal_name), val(apply_name), val(apply_args)
    output:
    tuple val(obsid), val(vis_name), path("hyp_${obsid}_${vis_name}.uvfits"), path("hyp_apply_${vis_name}.log")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"

    tag "${obsid}.${cal_name}_${apply_name}"
    label "cpu"

    module "gcc-rt/9.2.0"

    script:
    vis_name = "${cal_name}_${apply_name}"
    """
    # hyperdrive solutions apply uvfits
    ${params.hyperdrive} solutions-apply ${apply_args} \
        --data "${obsid}.metafits" "${obsid}.uvfits" \
        --solutions "hyp_soln_${obsid}_${cal_name}.fits" \
        --outputs "hyp_${obsid}_${vis_name}.uvfits" \
        | tee hyp_apply_${vis_name}.log

    # print out important info from log
    if [ \$(ls *.log 2> /dev/null | wc -l) -gt 0 ]; then
        grep -iE "err|warn|hyperdrive|chanblocks|reading|writing|flagged" *.log
    fi
    """
}

// ensure calibrated ms are present, or apply calsols to prep uvfits with hyperdrive
process hypApplyMS {
    input:
    tuple val(obsid), path("${obsid}.metafits"), path("${obsid}.uvfits"), path("hyp_soln_${obsid}_${cal_name}.fits"), \
        val(cal_name), val(apply_name), val(apply_args)
    output:
    tuple val(obsid), val(vis_name), path("hyp_${obsid}_${vis_name}.ms"), path("hyp_apply_${vis_name}_ms.log")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"
    // storeDir "/data/curtin_mwaeor/FRB_hopper/"

    tag "${obsid}.${cal_name}_${apply_name}"
    label "cpu"

    module "gcc-rt/9.2.0"

    script:
    vis_name = "${cal_name}_${apply_name}"
    """
    # hyperdrive solutions apply ms
    ${params.hyperdrive} solutions-apply ${apply_args} \
        --data "${obsid}.metafits" "${obsid}.uvfits" \
        --solutions "hyp_soln_${obsid}_${cal_name}.fits" \
        --outputs "hyp_${obsid}_${vis_name}.ms" \
        | tee hyp_apply_${vis_name}_ms.log

    # print out important info from log
    if [ \$(ls *.log 2> /dev/null | wc -l) -gt 0 ]; then
        grep -iE "err|warn|hyperdrive|chanblocks|reading|writing|flagged" *.log
    fi
    """
}

process hypSubUV {
    input:
    tuple val(obsid), val(name), path("${obsid}.metafits"), path("hyp_${obsid}_${name}.uvfits")
    output:
    tuple val(obsid), val(sub_name), path("hyp_${obsid}_${sub_name}.uvfits"), \
        path("hyp_vis-sub_${name}_uv.log")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"

    tag "${obsid}.${name}"
    label "gpu"

    module "gcc-rt/9.2.0"

    script:
    sub_name = "sub_${name}"
    """
    ${params.hyperdrive} vis-sub \
        --data "${obsid}.metafits" "hyp_${obsid}_${name}.uvfits" \
        --beam "${params.beam_path}" \
        --source-list "${params.sourcelist}" \
        --invert --num-sources 4000 \
        --outputs "hyp_${obsid}_${sub_name}.uvfits" \
        | tee hyp_vis-sub_${name}_uv.log
    # TODO: ^ num sources is hardcoded twice, would be better to re-use model from cal

    # print out important info from log
    if [ \$(ls *.log 2> /dev/null | wc -l) -gt 0 ]; then
        grep -iE "err|warn|hyperdrive|chanblocks|reading|writing|flagged" *.log
    fi
    """
}
process hypSubMS {
    input:
    tuple val(obsid), val(name), path("${obsid}.metafits"), path("hyp_${obsid}_${name}.ms")
    output:
    tuple val(obsid), val(sub_name), path("hyp_${obsid}_${sub_name}.ms"), \
        path("hyp_vis-sub_${name}_ms.log")

    storeDir "${params.outdir}/${obsid}/cal${params.cal_suffix}"

    tag "${obsid}.${name}"
    label "gpu"

    module "gcc-rt/9.2.0"

    script:
    sub_name = "sub_${name}"
    """
    ${params.hyperdrive} vis-sub \
        --data "${obsid}.metafits" "hyp_${obsid}_${name}.ms" \
        --beam "${params.beam_path}" \
        --source-list "${params.sourcelist}" \
        --invert --num-sources 4000 \
        --outputs "hyp_${obsid}_${sub_name}.ms" \
        | tee hyp_vis-sub_${name}_ms.log
    """
}

// QA tasks that can be run on each visibility file.
process visQA {
    input:
    tuple val(obsid), val(name), path("hyp_${obsid}_${name}.uvfits")
    output:
    tuple val(obsid), val(name), path("hyp_${obsid}_${name}_vis_metrics.json")

    storeDir "${params.outdir}/${obsid}/vis_qa"

    tag "${obsid}.${name}"

    label 'cpu'

    // needed for singularity
    module "miniconda/4.8.3"
    conda "${params.astro_conda}"

    script:
    """
    #!/bin/bash
    set -ex
    run_visqa.py *.uvfits --out "hyp_${obsid}_${name}_vis_metrics.json"
    """
}

// QA tasks that can be run on each calibration parameter set
process calQA {
    input:
    tuple val(obsid), val(name), path("${obsid}.metafits"), path("soln.fits")
    output:
    tuple val(obsid), val(name), path("hyp_soln_${obsid}_${name}_X.json")

    storeDir "${params.outdir}/${obsid}/cal_qa"

    tag "${obsid}.${name}"

    module "miniconda/4.8.3"
    conda "${params.astro_conda}"

    script:
    """
    #!/bin/bash
    set -ex
    run_calqa.py soln.fits ${obsid}.metafits --pol X --out "hyp_soln_${obsid}_${name}_X.json"
    """
}

process solJson {
    input:
    tuple val(obsid), val(dical_name), path("hyp_soln_${obsid}_${dical_name}.fits")
    output:
    tuple val(obsid), val(dical_name), path("hyp_soln_${obsid}_${dical_name}.fits.json")

    storeDir "${params.outdir}/${obsid}/cal_qa"
    tag "${obsid}.${dical_name}"

    module 'python/3.9.7'
    // module "miniconda/4.8.3"
    // conda "${params.astro_conda}"

    script:
    """
    #!/usr/bin/env python
    # this is nextflow-ified version of /astro/mwaeor/ctrott/poly_fit.py
    # TODO: this deserves its own version control

    from astropy.io import fits
    from json import dump as json_dump
    from collections import OrderedDict
    import numpy as np

    with \
        open('hyp_soln_${obsid}_${dical_name}.fits.json', 'w') as out, \
        fits.open("hyp_soln_${obsid}_${dical_name}.fits") as hdus \
    :
        data = OrderedDict()
        # Reads hyperdrive results from fits file into json
        results = hdus["RESULTS"].data[:,:]
        data["RESULTS"] = hdus["RESULTS"].data[:,:].tolist()
        data["DIPOLE_GAINS"] = hdus['TILES'].data["DipoleGains"].tolist()
        data["TOTAL_CONV"] = np.nanprod(results)
        print(repr(data))
        json_dump(data, out, indent=4)
    """
}

process plotSols {
    input:
    tuple val(obsid), val(name), path("${obsid}.metafits"), path("hyp_soln_${obsid}_${name}.fits")
    output:
    tuple val(obsid), path("hyp_soln_${obsid}*_${name}_{phases,amps}.png")

    storeDir "${params.outdir}/${obsid}/cal_qa"

    tag "${obsid}.${name}"

    script:
    """
    hyperdrive solutions-plot -m "${obsid}.metafits" *.fits
    """
}

process plotCalQA {
    input:
    tuple val(obsid), val(name), path("hyp_soln_${obsid}_${name}.json")
    output:
    tuple val(obsid), val(name), \
        path("calmetrics_${obsid}_${name}_fft.png"), \
        path("calmetrics_${obsid}_${name}_variance.png"), \
        path("calmetrics_${obsid}_${name}_dlyspectrum.png")

    storeDir "${params.outdir}/${obsid}/cal_qa"

    tag "${obsid}.${name}"

    module "miniconda/4.8.3"
    conda "${params.astro_conda}"

    script:
    """
    #!/bin/bash
    set -ex
    plot_calqa.py "hyp_soln_${obsid}_${name}.json" --out "calmetrics_${obsid}_${name}.png" --save
    """
}

// create dirty iamges of xx,yy,v
process wscleanDirty {
    input:
    tuple val(obsid), val(name), path("vis.ms")
    output:
    tuple val(obsid), val(name), path("wsclean_hyp_${obsid}_${name}-MFS-{XX,YY,V}-dirty.fits"), path("wsclean_${name}.log")

    storeDir "${params.outdir}/${obsid}/img${params.img_suffix}"

    tag "${obsid}.${name}"
    label "cpu"
    label "img"

    script:
    """
    set -eux
    # imaging
    ${params.wsclean} \
        -weight briggs -1.0 \
        -name wsclean_hyp_${obsid}_${name} \
        -size ${params.img_size} ${params.img_size} \
        -scale ${params.img_scale} \
        -pol xx,yy,v \
        -channels-out ${params.img_channels_out} \
        -niter ${params.img_niter} \
        vis.ms | tee wsclean_${name}.log
    # no need for `-abs-mem ${params.img_mem}` on DuG, we have the node to ourself
    """
}

// power spectrum metrics via chips
process psMetrics {
    input:
    tuple val(obsid), val(name), path("hyp_${obsid}_${name}.uvfits")
    output:
    tuple val(obsid), val(name), path("output_metrics_hyp_${obsid}_${name}.dat"), \
        path("hyp_${obsid}_${name}.log")

    storeDir "${params.outdir}/${obsid}/ps_metrics"

    tag "${obsid}.${name}"

    module "cfitsio/3.470:gcc-rt/9.2.0"

    script:
    band = 0
    nchan = 384
    uv_base = "hyp_${obsid}_${name}"
    """
    set -eux
    export DATADIR="\$PWD"
    export OUTPUTDIR="\$PWD/"
    ${params.ps_metrics} "${uv_base}" "${band}" "${nchan}" "${uv_base}" 2>&1 \
        | tee "${uv_base}.log"
    """
}

// takes dirty V and clean XX, YY for a single vis
process imgQA {
    input:
    tuple val(obsid), val(name), path("*") // <- "*-dirty.fits"
    output:
    tuple val(obsid), val(name), path("wsclean_hyp_${obsid}_${name}-MFS.json")

    storeDir "${params.outdir}/${obsid}/img_qa${params.img_suffix}"

    tag "${obsid}.${name}"

    module "miniconda/4.8.3"
    conda "${params.astro_conda}"

    script:
    // """
    // set -ex
    // singularity exec --bind \$PWD:/tmp --writable-tmpfs --pwd /tmp --no-home ${params.mwa_qa_sif} \
    //     run_imgqa.py *.fits --out wsclean_hyp_${obsid}_${name}-MFS.json
    // """

    """
    #!/bin/bash
    set -ex
    run_imgqa.py *.fits --out wsclean_hyp_${obsid}_${name}-MFS.json
    """
}

// polarimetry composite raster
process polComp {
    input:
    tuple val(obsid), val(name), path("*") // <- "*-dirty.fits"
    output:
    tuple val(obsid), val(name), path("${obsid}_${name}_polcomp.png")

    storeDir "${params.outdir}/${obsid}/img_qa${params.img_suffix}"

    tag "${obsid}.${name}"

    module "miniconda/4.8.3"
    conda "${params.astro_conda}"

    script:
    """
    #!${params.astro_conda}/bin/python

    from astropy.io import fits
    from astropy.visualization import astropy_mpl_style, make_lupton_rgb, simple_norm, SqrtStretch
    from astropy.visualization import ImageNormalize, PowerDistStretch, SinhStretch, LogStretch, AsinhStretch
    from astropy.visualization.lupton_rgb import AsinhMapping, LinearMapping
    from astropy.visualization.wcsaxes import WCSAxesSubplot, WCSAxes
    from astropy.wcs import WCS
    from matplotlib.patches import Rectangle, Circle
    from matplotlib.colors import LinearSegmentedColormap
    import matplotlib.pyplot as plt
    from mpl_toolkits.axes_grid1.axes_divider import AxesDivider, HBoxDivider, make_axes_locatable, Size
    from mpl_toolkits.axes_grid1.axes_rgb import make_rgb_axes
    from mpl_toolkits.axes_grid1.inset_locator import inset_axes
    import numpy as np
    from os.path import basename
    from glob import glob

    plt.style.use(astropy_mpl_style)

    header = None
    data = {}
    for key in ["XX", "YY", "V"]:
        path = glob(f"*${obsid}*${name}*{key}*.fits")[0]
        with fits.open(path) as hdus:
            if not header:
                header = hdus[0].header
            data[key] = hdus[0].data[0,0,:,:]

    wcs = WCS(header)
    img_size = header['NAXIS1'], header['NAXIS2']
    # TODO: beam stuff
    # cell_size = header['CDELT1'], header['CDELT2']
    # beam_shape = header['BMAJ'], header['BMIN'], header['BPA']

    # normalize 0-percentile to 0-1, use same percentile for XX and YY
    i_percentile = np.percentile(np.stack((data["XX"], data["YY"])), 99.5)
    v_percentile = np.percentile(data["V"], 99.5)
    norm = {
        "XX": data["XX"] / i_percentile,
        "YY": data["YY"] / i_percentile,
        "V": data["V"] / v_percentile,
    }

    rgbMap = AsinhMapping(0., stretch=3., Q=5.)
    rgb = rgbMap.make_rgb_image(norm["XX"], norm["V"], norm["YY"])

    sources = np.array([
        [0, -27], # eor0
        [6.4549166666666675, -26.04], # PKS0023_026
        # [45, -26.04]
    ])

    # stretch=AsinhStretch(0.05)
    # stretch=PowerDistStretch(0.05)
    stretch=SinhStretch()

    dpi = 100
    with plt.style.context('dark_background'):
        # axis setup
        img_fig = plt.figure(dpi=dpi, figsize=(img_size[0]/dpi, 4*img_size[1]/3/dpi))

        axd = img_fig.subplot_mosaic(
            [
                ["Comp", "XX"],
                ["Comp", "YY"],
                ["Comp", "V"],
            ],
            subplot_kw={"projection": wcs, "slices": ('x', 'y', 0, 0)},
            gridspec_kw={ "width_ratios": [3, 1], },
            sharex=True, sharey=True
        )

        for ax in axd.values():
            ax.set_ylabel("", visible=False)
            ax.set_xlabel("", visible=False)
            ax.set_label("")

        divider = AxesDivider(axd['Comp'])
        locator = divider.new_locator(nx=0, ny=0)
        axd['Comp'].set_axes_locator(locator)

        sub_xsize = (1/3) * Size.AxesX(axd['Comp'])
        cb_xsize = (1/10) * sub_xsize
        ysize = (1./3) * Size.AxesY(axd['Comp'])

        divider.set_horizontal([Size.AxesX(axd['Comp']), sub_xsize, cb_xsize])
        divider.set_vertical([ysize, ysize, ysize])

        axd['Comp'].set_axes_locator(divider.new_locator(0, 0, ny1=-1))
        axd["Comp"].tick_params(axis="y", direction="in", pad=-30, horizontalalighment="left")
        axd["Comp"].tick_params(axis="x", direction="in", pad=-20, verticalalignment="bottom")
        axd["Comp"].imshow(rgb)
        axd["Comp"].set_title("${obsid} - ${name}", y=0.95, fontdict={'verticalalignment':'top'})

        for key, ny, neg_col, pos_col, vmax in [
            ['XX', 2, 'cyan', 'red', i_percentile],
            ['YY', 1, 'yellow', 'blue', i_percentile],
            ['V', 0, 'magenta', 'green', v_percentile]
        ]:
            ax = axd[key]
            ax.set_title(key, y=0.95, fontdict={'verticalalignment':'top'})
            ax.set_axes_locator(divider.new_locator(nx=1, ny=ny))
            cmap = LinearSegmentedColormap.from_list(f'{neg_col}-bl-{pos_col}', [neg_col, 'black', pos_col], gamma=1)
            norm=ImageNormalize(data[key], vmin=-vmax, vmax=vmax, clip=False)
            im = ax.imshow(data[key], cmap=cmap, norm=norm)
            for coord in ax.coords:
                coord.set_ticklabel_visible(False)
            cax = inset_axes(
                ax,
                width="5%",
                height="100%",
                loc='lower left',
                bbox_to_anchor=(1.0, 0., 1, 1),
                bbox_transform=ax.transAxes,
                borderpad=0,
                axes_kwargs={ "axisbelow": False}
            )
            cbar = img_fig.colorbar(im, cax=cax)

        for ax in axd.values():
            ax.scatter(sources[:,0], sources[:,1], s=100, edgecolor='white', facecolor='none', transform=ax.get_transform('world'))
            ax.add_patch(Rectangle((0, 0), 100, 100, edgecolor='white', fill=False, zorder=999))

        #  hist_ax = inset_axes(
        #      axd["Comp"],
        #      width="100%",
        #      height="20%",
        #      loc='lower left',
        #      bbox_to_anchor=(0., -0.25, 1, 1),
        #      bbox_transform=axd['Comp'].transAxes,
        #      borderpad=0,
        #  )

        #  hist_ax.hist(data["XX"].flatten(), bins=1000, color='red', alpha=0.5, histtype='step')
        #  hist_ax.hist(data["YY"].flatten(), bins=1000, color='blue', alpha=0.5, histtype='step')
        #  hist_ax.hist(data["V"].flatten(), bins=1000, color='green', alpha=0.5, histtype='step')

        plt.savefig('${obsid}_${name}_polcomp.png', bbox_inches='tight', dpi=dpi)
    """
}

import groovy.json.JsonSlurper
import groovy.json.StringEscapeUtils
jslurp = new JsonSlurper()
def parseJson(path) {
    // TODO: fix nasty hack to deal with NaNs
    jslurp.parseText(path.getText().replaceAll(/(NaN|-?Infinity)/, '"NaN"'))
}

import java.text.SimpleDateFormat
SimpleDateFormat logDateFmt = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");

// display a long list of ints, replace bursts of consecutive numbers with ranges
def displayRange = { s, e -> s == e ? "${s}," : s == e - 1 ? "${s},${e}," : "${s}-${e}," }
max_ints_display = 50
def displayInts = { l ->
    switch (l) {
        case { it.size() == 0 }: return "";
        case { it.size() == 1 }: return displayRange(l[0],l[0]);
        default:
            def sb, start, end
            (sb, start, end) = [''<<'', l[0], l[0]]
            for (i in l[1..-1]) {
                (sb, start, end) = i == end + 1 ? [sb, start, i] : [sb << displayRange(start, end), i, i]
            }
            result = (sb << displayRange(start, end))[0..-2].toString()
            if (result.size() > max_ints_display) {
                return result.substring(0, (max_ints_display-1).intdiv(2))
                << "..."
                << result.substring(result.size() - (max_ints_display-1).intdiv(2))
            } else {
                return result
            }
    }
}

// collapse a list into its contiguous ranges
def contigRanges(l) {
    switch (l) {
        case { it.size() == 0 }: return [];
        case { it.size() == 1 }: return [(l[0]..l[0])]
        default:
            def sb, start, end
            (sb, start, end) = [[], l[0], l[0]]
            for (i in l.tail()) {
                (sb, start, end) = i == end + 1 ? [sb, start, i] : [sb << (start..end), i, i]
            }
            return (sb << (start..end))[0..-1]
    }
}

unit_conversions = [
    "s": 1,
    "ms": 1e-3,
    "µs": 1e-6,
    "ns": 1e-9,
]
def get_seconds(float time, String unit) {
    if (unit_conversions[unit] == null) {
        println "unknown duration unit ${unit} for time ${time}";
        time
    } else {
        time * unit_conversions[unit]
    }
}

// use mwa webservices to gate obsids by pointing and faults
workflow ws {
    take:
        // channel of obs ids
        obsids

    main:
        obsids | wsMeta

        wsSummary = wsMeta.out.map { def (obsid, json) = it;
                // parse json
                def stats = parseJson(json)
                def pointing = stats.metadata.gridpoint_number
                def nscans = ((stats.stoptime?:0) - (stats.starttime?:0)) / (stats.int_time?:1)
                def delays = (stats.alldelays?:[:]).values().flatten()
                def quality = stats.quality?:[:]
                def tiles = stats.tdict?:[:]
                def bad_tiles = stats.bad_tiles?:[:]
                def dead_dipoles = delays.count { it == 32 }
                def dead_dipole_frac = dead_dipoles / delays.size()
                def dataquality = stats.dataquality
                def dataqualitycomment = stats.dataqualitycomment?:''
                def faults = stats.faults?:[:]
                def badstates = (faults.badstates?:[:]).values().flatten()
                def badpointings = (faults.badpointings?:[:]).values().flatten()
                def badfreqs = (faults.badfreqs?:[:]).values().flatten()
                def badgains = (faults.badgains?:[:]).values().flatten()
                def badbeamshape = (faults.badbeamshape?:[:]).values().flatten()
                def significant_faults = badstates.size() + badfreqs.size() + badgains.size()
                def fail_reasons = []
                if (!params.filter_pointings.contains(pointing)) {
                    fail_reasons += ["pointing=${pointing}"]
                }
                if (dataquality != 1) {
                    fail_reasons += ["dataquality=${dataquality}"]
                }
                if (bad_tiles.size() / tiles.size() > params.filter_bad_tile_frac) {
                    fail_reasons += ["bad_tiles(${bad_tiles.size()})=${displayInts(bad_tiles)}"]
                }
                if (dead_dipole_frac > params.filter_dead_dipole_frac) {
                    fail_reasons += ["dead_dipole_frac=${dead_dipole_frac}"]
                }
                def summary = [
                    fail_reasons: fail_reasons,
                    // obs metadata
                    nscans: nscans,
                    ra_pointing: stats.metadata.ra_pointing,
                    dec_pointing: stats.metadata.dec_pointing,
                    ra_phase_center: stats.ra_phase_center?:stats.metadata.ra_pointing,
                    dec_phase_center: stats.dec_phase_center?:stats.metadata.dec_pointing,
                    pointing: pointing,
                    lst: stats.metadata.local_sidereal_time_deg,
                    freq_res: stats.freq_res,
                    int_time: stats.int_time,
                    tiles: tiles,
                    bad_tiles: bad_tiles,
                    // iono quality
                    iono_magnitude: quality.iono_magnitude?:'',
                    iono_pca: quality.iono_pca?:'',
                    iono_qa: quality.iono_qa?:'',
                    // data quality
                    dataquality: dataquality,
                    dataqualitycomment: dataqualitycomment,
                    // fraction of flagged tiles
                    flagtilefrac: bad_tiles.size() / tiles.size(),
                    // fraction of dead dipoles
                    dead_dipole_frac: dead_dipole_frac,
                    // faults
                    badstates: badstates.size(),
                    badpointings: badpointings.size(),
                    badfreqs: badfreqs.size(),
                    badgains: badgains.size(),
                    badbeamshape: badbeamshape.size(),
                    significant_faults: significant_faults,
                    faultstring: faults.shortstring.replaceAll(/\n\s*/, '|'),
                    // files
                    files: stats.files.toString(),
                    num_data_files: stats.num_data_files,
                    num_data_files_archived: stats.num_data_files_archived,
                ]
                [obsid, summary]
            }

        // display wsSummary
        wsSummary.map { def (obsid, summary) = it;
                [
                    obsid,
                    summary.fail_reasons.join('|'),
                    summary.ra_pointing,
                    summary.dec_pointing,
                    summary.ra_phase_center,
                    summary.dec_phase_center,
                    summary.pointing,
                    summary.lst,
                    summary.freq_res,
                    summary.int_time,
                    summary.nscans,
                    summary.dataquality,
                    summary.dataqualitycomment,
                    summary.dead_dipole_frac,
                    summary.flagtilefrac,
                    displayInts(summary.bad_tiles),
                    summary.iono_magnitude,
                    summary.iono_pca,
                    summary.iono_qa,
                    summary.badstates,
                    summary.badpointings,
                    summary.badfreqs,
                    summary.badgains,
                    summary.badbeamshape,
                    summary.significant_faults,
                    summary.faultstring
                ].join("\t")
            }
            .collectFile(
                name: "ws_stats.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "FAIL REASON", "RA POINT", "DEC POINT", "RA PHASE", "DEC PHASE", "POINT", "LST DEG",
                    "FREQ RES", "TIME RES","N SCANS", "QUALITY", "QUALITY COMMENT",
                    "DEAD DIPOLE FRAC","FLAG TILES FRAC", "FLAG TILES",
                    "IONO MAG", "IONO PCA", "IONO QA",
                    "STATE FAULTS", "POINTING FAULTS", "FREQ FAULTS", "GAIN FAULTS", "BEAM FAULTS", "SIGNIFICANT FAULTS"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/",
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

    emit:
        // channel of good obsids
        pass = wsSummary
            .filter { def (_, summary) = it; summary.fail_reasons == [] }
            .map { def (obsid, _) = it; obsid }
}

// ensure raw files are downloaded
workflow raw {
    take:
        // channel of obs ids
        obsids
    main:
        asvoRaw(obsids)

        // collect disk usage stats from asvoRaw stage
        asvoRaw.out
            // form row of tsv
            .map { def (obsid, metafits, gpuboxes) = it; [
                obsid,
                metafits.size(), // size of metafits [B]
                gpuboxes.size(), // number of gpubox files
                gpuboxes.collect(path -> path.size()).sum() // total gpubox size [B]
            ].join("\t") }
            .collectFile(
                name: "raw_stats.tsv", newLine: true, sort: true,
                // "seed" is the header of the tsv file
                seed: ["OBS","META SIZE","N GPUBOX","GPUBOX SIZE"].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        // analyse metafits stats
        asvoRaw.out
            .map { def (obsid, metafits, _) = it; [obsid, metafits] }
            | metaJson

        // collect metafits stats
        metaJson.out
            // for row of tsv from metafits json fields we care about
            .map { def (obsid, json) = it;
                def stats = jslurp.parse(json)
                // def row = [obsid]
                // row += [
                //     "DATE-OBS", "GRIDNUM", "CENTCHAN", "FINECHAN", "INTTIME",
                //     "NSCANS", "NINPUTS"
                // ].collect { stats.get(it) }
                def flagged_inputs = stats.FLAGGED_INPUTS?:[]
                def delays = (stats.DELAYS?:[]).flatten()
                [
                    obsid,
                    stats."DATE-OBS",
                    stats.RA,
                    stats.DEC,
                    stats.GRIDNUM,
                    stats.CENTCHAN,
                    stats.FINECHAN,
                    stats.INTTIME,
                    stats.NSCANS,
                    stats.NINPUTS,
                    (delays.count { it == 32 } / delays.size()), // fraction of dead dipole
                    flagged_inputs.size(), // number of flagged inputs
                    flagged_inputs.join('\t') // flagged input names
                ].join("\t")
            }
            .collectFile(
                name: "metafits_stats.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "DATE", "RA", "DEC", "POINT",
                    "CENT CH","FREQ RES",
                    "TIME RES","N SCANS",
                    "N INPS","DEAD DIPOLE FRAC","N FLAG INPS","FLAG INPS"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/",
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

    emit:
        // channel of all raw files: tuple(obsid, metafits, gpuboxes)
        obsRawFiles = asvoRaw.out
}

// ensure preprocessed uvfits and flags have been generated from raw files
workflow prep {
    take:
        // channel of raw files: tuple(obsid, metafits, gpuboxes)
        obsRawFiles
    main:
        // preprocess raw files with Birli
        obsRawFiles
            // set spw to ""
            .map { def (obsid, metafits, gpuboxes) = it; [obsid, "", metafits, gpuboxes] }
            | birliPrep

        // get info about preprocessing stage
        birliPrep.out
            .map { def (obsid, _, prepUVFits, __, ___) = it; [obsid, prepUVFits] }
            | prepStats

        // collect prep stats
        prepStats.out
            // join with uvfits, mwaf and birli log
            .join( birliPrep.out.map { def (obsid, _, prepUVFits, prepMwafs, prepLog) = it;
                [obsid, prepUVFits, prepMwafs, prepLog]
            })
            // form row of tsv from json fields we care about
            .map { def (obsid, json, prepVis, prepMwafs, prepLog) = it;
                def stats = jslurp.parse(json)
                // parse birli log for missing hdus
                def missing_hdus = (prepLog.getText() =~ /NoDataForTimeStepCoarseChannel \{ timestep_index: (\d+), coarse_chan_index: (\d+) \}/)
                    .collect { m -> [tstep:m[1], cchan:m[2]] }
                // parse birli for missing durations
                def durations = (prepLog.getText() =~ /(\w+) duration: ([\d.]+)([^\d.\s]*)/)
                    .collect()
                    .collectEntries  { m ->
                        def (stage, time, unit) = [m[1].toString(), m[2] as float, m[3].toString()]
                        [(stage):get_seconds(time, unit)]
                    }
                // display a compressed version of missing hdus
                def missing_timesteps_by_gpubox = missing_hdus
                    .groupBy { m -> m.cchan }
                    .collect { cchan, pairs ->
                        [cchan as int, displayInts(pairs.collect {pair -> pair.tstep as int})].join(":")
                    }
                    .sort();
                [
                    obsid,
                    // prep stats json
                    stats.num_chans,
                    stats.num_times,
                    stats.num_baselines,
                    // disk usage
                    prepVis.size(), // size of uvfits [B]
                    prepMwafs.size(), // number of mwaf
                    prepMwafs.collect(path -> path.size()).sum(), // total mwaf size [B]
                    // parse birli log durations
                    durations?.read?:'',
                    durations?.flag?:'',
                    durations?.correct_passband?:'',
                    durations?.correct_digital?:'',
                    durations?.correct_geom?:'',
                    durations?.correct_cable?:'',
                    durations?.write?:'',
                    durations?.total?:'',
                    missing_hdus.size(),
                    missing_timesteps_by_gpubox.join("|"),
                ].join("\t")
            }
            .collectFile(
                name: "prep_stats.tsv", newLine: true, sort: true,
                seed: [
                    "OBS","N CHAN","N TIME","N BL","UVFITS BYTES", "N MWAF","MWAF BYTES",
                    "DUR READ", "DUR FLAG", "DUR CORR PB", "DUR CORR DIG", "DUR CORR GEOM",
                    "DUR CORR CABLE", "DUR WRITE", "DUR TOTAL",
                    "MISSING HDUs"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }
    emit:
        // channel of preprocessed files: tuple(obsid, prepUVFits)
        obsPrepUVFits = birliPrep.out.map { def (obsid, _, prepUVFits, __) = it; [obsid, prepUVFits] }
        // channel of mwaf files for each obsid: tuple(obsid, mwafs)
        obsMwafs = birliPrep.out.map { def (obsid, _, __, prepMwafs) = it; [obsid, prepMwafs] }
}

// only emit obsids which pass flag occupancy threshold
workflow flagGate {
    take:
        // channel of required files: tuple(obsid, metafits, mwafs)
        flagFiles

    main:
        // analyse flag occupancy
        flagFiles | flagQA

        // collect flagQA results
        // TODO: collect sky_chans from flagQA
        def sky_chans = (131..154).collect { ch -> "$ch".toString() }
        flagQA.out
            // form row of tsv from json fields we care about
            .map { def (obsid, json) = it;
                def stats = jslurp.parse(json)
                def chan_occupancy = sky_chans.collect { ch -> (stats.channels?[ch]?.non_preflagged_bl_occupancy)?:'' }
                ([obsid, stats.total_occupancy, stats.total_non_preflagged_bl_occupancy] + chan_occupancy).join("\t")
            }
            .collectFile(
                name: "occupancy.tsv", newLine: true, sort: true,
                seed: (["OBS", "TOTAL OCCUPANCY", "NON PREFLAGGED"] + sky_chans).join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

    emit:
        // channel of obsids which pass the flag gate
        pass = flagQA.out
            .map { def (obsid, json) = it; [obsid, jslurp.parse(json).total_occupancy] }
            .filter { def (_, occ) = it; occ && occ < params.flag_occupancy_threshold }
            .map { def (obsid, _) = it; obsid }
}

workflow cal {
    take:
        // channel of metafits and preprocessed uvfits: tuple(obsid, metafits, uvfits)
        obsMetaVis
    main:
        // hyperdrive di-calibrate on each obs
        obsMetaVis
            .map { def (obsids, metafits, uvfits) = it
                [obsids, params.dical_args, metafits, uvfits]
            }
            | hypCalSol

        // channel of solutions for each unflagged obsid: tuple(obsid, solutions)
        obsSolns = hypCalSol.out.map { def (obsid, solutions) = it; [obsid, solutions] }
        // channel of metafits for each obsid: tuple(obsid, metafits)
        obsMetafits = obsMetaVis.map { def (obsid, metafits, _) = it; [obsid, metafits] }

        // hyperdrive dical log analysis
        hypCalSol.out.map { def (obsid, _, diCalLog) = it;
                def startTime = logDateFmt.parse((diCalLog.getText() =~ /([\d: -]+) INFO  hyperdrive di-calibrate/)[0][1])
                def convergedMatch = (diCalLog.getText() =~ /([\d: -]+) INFO  All timesteps: (\d+)\/(\d+)/)[0]
                def convergedTime = logDateFmt.parse(convergedMatch[1])
                def convergedNumerator = convergedMatch[2] as int
                def convergedDenominator = convergedMatch[3] as int
                def convergedDurationSec = (convergedTime.time - startTime.time) / 1000

                [obsid, convergedDurationSec, convergedNumerator, convergedDenominator].join("\t")
            }
            .collectFile(
                name: "cal_timings.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "CAL DUR", "CHS CONVERGED", "CHS TOTAL"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )

        // channel of individual dical solutions: tuple(obsid, name, soln)
        // - hypCalSol gives multiple solutions, transpose gives 1 tuple per solution.
        eachCal = obsSolns
            .transpose()
            .map { def (obsid, soln) = it
                // give each calibration a name from basename of solution fits
                def name = soln.getBaseName().split('_')[3..-1].join('_')
                [obsid, name, soln]
            }

        // do polyfit, generate json from solns
        eachCal | (polyFit & solJson)

        // collect solJson results as .tsv
        solJson.out
            // form row of tsv from json fields we care about
            .map { def (obsid, name, json) = it;
                def stats = parseJson(json)
                def results = stats.RESULTS?[0]?:[]
                def (nans, convergences) = results.split { it == "NaN" }
                [
                    obsid,
                    name,
                    nans.size() / results.size(),
                    results.join('\t')
                ].join("\t")
            }
            .collectFile(
                name: "cal_results.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "CAL NAME", "NAN FRAC", "RESULTS BY CH"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        // calibration QA and plot solutions
        obsMetafits
            // join with hyp_soln from ensureCal
            .cross(eachCal.mix(polyFit.out))
            .map { def (obsid, metafits) = it[0]; def (_, name, soln) = it[1]
                [obsid, name, metafits, soln]
            }
            | (plotSols & calQA)

        // plot calQA results
        calQA.out | plotCalQA

        // collect calQA results as .tsv
        calQA.out
            // form row of tsv from json fields we care about
            .map { def (obsid, name, json) = it;
                def stats = parseJson(json)
                [
                    obsid,
                    name,
                    (stats.UNUSED_BLS?:0) / 100,
                    (stats.UNUSED_CHS?:0) / 100,
                    (stats.UNUSED_ANTS?:0) / 100,
                    (stats.NON_CONVERGED_CHS?:0) / 100,
                    stats.CONVERGENCE_VAR?[0],
                    stats.CONVERGENCE_VAR?[0] == "NaN" ? "NaN" : stats.CONVERGENCE_VAR?[0] * 1e14,
                    stats.XX?.SKEWNESS_UVCUT?:'',
                    stats.XX?.RMS_AMPVAR_ANT?:'',
                    stats.XX?.RMS_AMPVAR_FREQ?:'',
                    stats.XX?.DFFT_POWER?:'',
                    stats.XX?.RECEIVER_CHISQVAR?:'',
                    stats.YY?.SKEWNESS_UVCUT?:'',
                    stats.YY?.RMS_AMPVAR_ANT?:'',
                    stats.YY?.RMS_AMPVAR_FREQ?:'',
                    stats.YY?.DFFT_POWER?:'',
                    stats.YY?.RECEIVER_CHISQVAR?:'',
                ].join("\t")
            }
            .collectFile(
                name: "cal_metrics.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "CAL NAME",
                    "BL UNUSED FRAC", "CH UNUSED FRAC", "ANT UNUSED FRAC",
                    "NON CONVG CHS FRAC",
                    "CONVG VAR",
                    "CONVG VAR e14",
                    "XX SKEW UVCUT",
                    "XX RMS AMPVAR ANT",
                    "XX RMS AMPVAR FREQ",
                    "XX DFFT POWER",
                    "XX RECEIVER CHISQVAR",
                    "YY SKEW UVCUT",
                    "YY RMS AMPVAR ANT",
                    "YY RMS AMPVAR FREQ",
                    "YY DFFT POWER",
                    "YY RECEIVER CHISQVAR",
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        // hyperdrive apply-solutions using apply solution args file:
        // - take tuple(obsid, cal_name, soln) from both eachCal and polyFit
        // - lookup [apply_name, apply_args] from params.apply_args on cal_name
        // - match with tuple(obsid, metafits, prepUVFits) by obsid
        obsMetaVis
            .cross(
                eachCal
                    .mix(polyFit.out)
                    .filter { def (obsid, cal_name, soln) = it;
                        params.apply_args[cal_name] != null
                    }
                    .map { def (obsid, cal_name, soln) = it;
                        def (apply_name, apply_args) = params.apply_args[cal_name]
                        [obsid, soln, cal_name, apply_name, apply_args]
                    }
            )
            .map {
                def (obsid, metafits, prepUVFits) = it[0]
                def (_, soln, cal_name, apply_name, apply_args) = it[1]
                [obsid, metafits, prepUVFits, soln, cal_name, apply_name, apply_args]
            }
            | (hypApplyUV & hypApplyMS)

        // get subtracted uvfits vis
        obsMetaVis
            .cross(
                hypApplyUV.out
                    // TODO: exclude poly_50l without hardcoding twice.
                    .filter { def (_, name) = it; !(name ==~ /poly_50l.*/) }
            )
            .map {
                def (obsid, metafits, _) = it[0]
                def (__, name, vis) = it[1];
                [obsid, name, metafits, vis]
            }
            | hypSubUV

        // get subtracted ms vis
        obsMetaVis
            .cross(
                hypApplyMS.out
                    // TODO: exclude poly_50l without hardcoding twice.
                    .filter { def (_, name) = it; !(name ==~ /poly_50l.*/) }
            )
            .map {
                def (obsid, metafits, _) = it[0]
                def (__, name, vis) = it[1];
                [obsid, name, metafits, vis]
            }
            | hypSubMS

    emit:
        // channel of calibrated or subtracted uvfits: tuple(obsid, name, uvfits)
        obsNameUvfits = hypApplyUV.out
            .mix(hypSubUV.out)
            .map { def (obsid, name, vis) = it; [obsid, name, vis] }
        // channel of calibrated measurement sets: tuple(obsid, name, ms)
        obsNameMS = hypApplyMS.out
            .mix(hypSubMS.out)
            .map { def (obsid, name, vis) = it; [obsid, name, vis] }
}

// process uvfits visibilities
workflow uvfits {
    take:
        obsNameUvfits
    main:
        // vis QA and ps_metrics
        obsNameUvfits | psMetrics
        // TODO: tap?
        obsNameUvfits
            .filter { def (_, name) = it; !name.toString().startsWith("sub_") }
            | visQA

        // collect visQA results as .tsv
        visQA.out
            // form row of tsv from json fields we care about
            .map { def (obsid, name, json) = it;
                def stats = parseJson(json);
                [
                    obsid,
                    name,
                    stats.AUTOS?.XX?.MEAN_RMS_AMPS?:'',
                    stats.AUTOS?.XX?.VAR_RMS_AMPS?:'',
                    stats.AUTOS?.XX?.MEAN_RMS_PHS?:'',
                    stats.AUTOS?.XX?.VAR_RMS_PHS?:'',
                    stats.AUTOS?.XX?.MX_VAR_DIFF_AMPS?:'',
                    stats.AUTOS?.XX?.MX_VAR_DIFF_PHS?:'',
                    stats.AUTOS?.YY?.MEAN_RMS_AMPS?:'',
                    stats.AUTOS?.YY?.VAR_RMS_AMPS?:'',
                    stats.AUTOS?.YY?.MEAN_RMS_PHS?:'',
                    stats.AUTOS?.YY?.VAR_RMS_PHS?:'',
                    stats.AUTOS?.YY?.MX_VAR_DIFF_AMPS?:'',
                    stats.AUTOS?.YY?.MX_VAR_DIFF_PHS?:'',
                    stats.REDUNDANT?.XX?.VAR_AMP_CHISQ?:'',
                    stats.REDUNDANT?.XX?.VAR_PHS_CHISQ?:'',
                    stats.REDUNDANT?.XX?.MVAR_AMP_DIFF?:'',
                    stats.REDUNDANT?.XX?.MVAR_PHS_DIFF?:'',
                    stats.REDUNDANT?.YY?.VAR_AMP_CHISQ?:'',
                    stats.REDUNDANT?.YY?.VAR_PHS_CHISQ?:'',
                    stats.REDUNDANT?.YY?.MVAR_AMP_DIFF?:'',
                    stats.REDUNDANT?.YY?.MVAR_PHS_DIFF?:'',
                    // stats.AUTOS?.XX?.POOR_TIMES?[0],
                    // stats.AUTOS?.YY?.POOR_TIMES?[0]
                ].join("\t")
            }
            .collectFile(
                name: "vis_metrics.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "VIS NAME",
                    "A:XX MEAN RMS AMPS",
                    "A:XX VAR RMS AMPS",
                    "A:XX MEAN RMS PHS",
                    "A:XX VAR RMS PHS",
                    "A:XX MX VAR DIFF AMPS",
                    "A:XX MX VAR DIFF PHS",
                    "A:YY MEAN RMS AMPS",
                    "A:YY VAR RMS AMPS",
                    "A:YY MEAN RMS PHS",
                    "A:YY VAR RMS PHS",
                    "A:YY MX VAR DIFF AMPS",
                    "A:YY MX VAR DIFF PHS",
                    "R:XX VAR AMP CHISQ",
                    "R:XX VAR PHS CHISQ",
                    "R:XX MVAR AMP DIFF",
                    "R:XX MVAR PHS DIFF",
                    "R:YY VAR AMP CHISQ",
                    "R:YY VAR PHS CHISQ",
                    "R:YY MVAR AMP DIFF",
                    "R:YY MVAR PHS DIFF",
                    // "XX POOR TIMES", "YY POOR TIMES"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        // collect psMetrics as a .dat
        psMetrics.out
            // read the content of each ps_metrics file including the trailing newline
            .map { def (obsid, vis_name, dat) = it; dat.getText() }
            .collectFile(
                name: "ps_metrics.dat",
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        // collect psMetrics as a .tsv
        psMetrics.out
            // form each row of tsv
            .map { def (obsid, vis_name, dat) = it;
                def dat_values = dat.getText().split('\n')[0].split(' ')[1..-1]
                ([obsid, vis_name] + dat_values).join("\t")
            }
            .collectFile(
                name: "ps_metrics.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "CAL NAME", "P_WEDGE", "NUM_CELLS", "P_WINDOW", "NUM_CELLS",
                    "P_ALL", "D3"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }
}

// image measurement sets and QA images
workflow img {
    take:
        obsNameMS
    main:
        // wsclean: make dirty images
        obsNameMS | wscleanDirty

        // imgQA for all groups of images
        wscleanDirty.out
            .map { def (obsid, name, imgs) = it; [obsid, name, imgs] }
            | (imgQA & polComp)

        // collect imgQA results as .tsv
        imgQA.out
            // form row of tsv from json fields we care about
            .map { def (obsid, name, json) = it;
                // parse json
                // def stats = jslurp.parse(json)
                // TODO: fix nasty hack to deal with NaNs
                def stats = parseJson(json)
                [
                    obsid,
                    name,
                    stats.XX?.RMS_ALL, stats.XX?.RMS_BOX, stats.XX?.PKS0023_026?.PEAK_FLUX, stats.XX?.PKS0023_026?.INT_FLUX,
                    stats.YY?.RMS_ALL, stats.YY?.RMS_BOX, stats.YY?.PKS0023_026?.PEAK_FLUX, stats.YY?.PKS0023_026?.INT_FLUX,
                    stats.V?.RMS_ALL, stats.V?.RMS_BOX, stats.V?.PKS0023_026?.PEAK_FLUX, stats.V?.PKS0023_026?.INT_FLUX,
                    stats.V_XX?.RMS_RATIO, stats.V_XX?.RMS_RATIO_BOX
                ].join("\t")
            }
            .collectFile(
                name: "img_metrics.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "IMG NAME",
                    "XX RMS ALL", "XX RMS BOX", "XX PKS0023_026 PEAK", "XX PKS0023_026 INT",
                    "YY RMS ALL", "YY RMS BOX", "YY PKS0023_026 PEAK", "YY PKS0023_026 INT",
                    "V RMS ALL","V RMS BOX", "V PKS0023_026 PEAK", "V PKS0023_026 INT" ,
                    "V:XX RMS RATIO", "V:XX RMS RATIO BOX"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

        polComp.out.map { def (obsid, name, png) = it;
                [obsid, name, png].join("\t")
            }
            .collectFile(
                name: "pol_comp.tsv", newLine: true, sort: true,
                seed: [
                    "OBS", "IMG NAME", "PNG"
                ].join("\t"),
                storeDir: "${params.outdir}/results${params.result_suffix}/"
            )
            // display output path and number of lines
            | view { [it, it.readLines().size()] }

}

workflow {
    // get obsids from csv
    obsids = channel.fromPath(params.obsids_path).splitCsv().flatten()

    // analyse obsids with web services
    obsids | ws
    filteredObsids = ws.out.pass
    filteredObsids.collectFile(
        name: "filtered_obsids.csv", newLine: true, sort: true,
        storeDir: "${params.outdir}/results${params.result_suffix}/"
    )
    | view { [it, it.readLines().size()] }

    // download and preprocess raw obsids
    filteredObsids | raw | prep

    // channel of metafits for each obsid: tuple(obsid, metafits)
    obsMetafits = raw.out.map { def (obsid, metafits, _) = it; [obsid, metafits] }

    // channel of obsids that pass the flag gate
    unflaggedObsids = obsMetafits.join(prep.out.obsMwafs) | flagGate
    unflaggedObsids.collectFile(
        name: "unflagged_obsids.csv", newLine: true, sort: true,
        storeDir: "${params.outdir}/results${params.result_suffix}/"
    )
    | view { [it, it.readLines().size()] }

    // calibrate each obs that passes flag gate:
    unflaggedObsids.join(obsMetafits).join(prep.out.obsPrepUVFits) | cal

    // QA uvfits visibilities
    cal.out.obsNameUvfits | uvfits

    // QA images of measurementsets
    cal.out.obsNameMS | img
}