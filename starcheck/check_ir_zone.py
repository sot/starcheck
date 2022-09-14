import numpy as np

import kadi.commands
import kadi.commands.states
from cxotime import CxoTime


def ir_zone_ok(backstop_file, out=None, pad_minutes=30):

    pad_seconds = pad_minutes * 60

    bs_cmds = kadi.commands.get_cmds_from_backstop(backstop_file)
    bs_dates = bs_cmds['date']
    ok = bs_cmds['event_type'] == 'RUNNING_LOAD_TERMINATION_TIME'
    rltt = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[0])

    # Scheduled stop time is the end of propagation, either the explicit
    # time as a pseudo-command in the loads or the last backstop command time.
    ok = bs_cmds['event_type'] == 'SCHEDULED_STOP_TIME'
    sched_stop = CxoTime(bs_dates[ok][0] if np.any(ok) else bs_dates[-1])

    # Get the states for available commands.  This automatically gets continuity.
    state_keys = ['pcad_mode', 'obsid']
    states = kadi.commands.states.get_states(cmds=bs_cmds, start=rltt, stop=sched_stop,
                                             state_keys=state_keys, merge_identical=True)

    perigee_cmds = bs_cmds[(bs_cmds['type'] == 'ORBPOINT')
                           & (bs_cmds['event_type'] == 'EPERIGEE')]

    all_ok = True
    out_text = ["IR ZONE CHECKING"]
    for perigee_time in perigee_cmds['time']:
        ir_zone_start = perigee_time - pad_seconds
        ir_zone_stop = perigee_time
        out_text.append(
            f"Checking perigee at {CxoTime(perigee_time).date}")
        out_text.append(
            f"  High IR Zone from {CxoTime(ir_zone_start).date} to {CxoTime(ir_zone_stop).date}")
        ok = (states['tstart'] <= ir_zone_stop) & (states['tstop'] >= ir_zone_start)
        for state in states[ok]:
            out_text.append(
                f"  state {state['datestart']} {state['datestop']} {state['pcad_mode']}")
        if np.any(states[ok]['pcad_mode'] != 'NMAN'):
            all_ok = False

    if out is not None:
        with open(out, 'w') as fh:
            fh.writelines("\n".join(out_text))

    return all_ok
