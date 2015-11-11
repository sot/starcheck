import hopper

def make_pcad_attitude_check_report(backstop_file, or_list_file=None,
                                    ofls_characteristics_file=None, out=None,
                                    ):
    """
    Make a report for checking PCAD attitudes

    """

    # Run the commands and populate attributes in `sc`, the spacecraft state.
    # In particular sc.checks is a dict of checks by obsid.
    # Any state value (e.g. obsid or q_att) has a corresponding plural that
    # gives the history of updates as a dict with a `value` and `date` key.
    # This does not define the initial state from continuity at this time.
    sc = hopper.run_cmds(backstop_file, or_list_file, ofls_characteristics_file,
                         initial_state=None)

    all_ok = True

    # Iterate through obsids in order
    lines = []
    obsids = [obj['value'] for obj in sc.obsids]
    for obsid in obsids:
        if obsid not in sc.checks:
            continue

        checks = sc.checks[obsid]
        for check in checks:
            if check['name'] == 'CheckObsreqTargetFromPcad':
                ok = check['ok']
                all_ok &= ok
                if check.get('skip'):
                    message = 'SKIPPED: {}'.format(check['message'])
                else:
                    message = 'OK' if ok else check['message']
                line = '{:5d}: {}'.format(obsid, message)
                lines.append(line)

    if out is not None:
       report = open(out, 'w')
       report.writelines("\n".join(lines))

    return all_ok
