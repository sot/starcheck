import numpy as np
from cxotime import CxoTime

from astropy.table import Table, vstack
import astropy.units as u
from functools import lru_cache
import numpy as np

import kadi.commands as kadi_commands
import kadi.commands.states as kadi_states
from cxotime import CxoTime
from chandra_maneuver import duration
from Quaternion import Quat


@lru_cache
def make_man_table():
    """
    Compute a lookup table of maneuver angles and durations.

    This function calculates the durations for a range of maneuver angles and makes an astropy
    table of the results. The durations are calculated using chandra_maneuver.duration.

    Returns:
    -------
    Table
        An astropy Table containing the durations and corresponding maneuver angles.

    """
    durations = []
    q0 = Quat(equatorial=(0, 0, 0))

    # Use a range of angles that sample the curve pretty well by eye
    # The duration function is a little slow and not vectorized, so
    # this is sparse.
    angles = [0, 5, 10, 15, 20, 25, 35, 50, 100, 150, 180]
    for angle in angles:
        q1 = Quat(equatorial=(angle, 0, 0))
        durations.append(duration(q0, q1))

    return Table([durations, angles], names=["duration", "angle"])


@lru_cache
def get_pcad_states(backstop_file):
    """
    Get the pcad_mode kadi command states for the products in review (as defined by the backstop_file
    and continuity).

    Parameters:
    ----------
    backstop_file : str
        The path to the backstop file.

    Returns:
    -------
    states : astropy Table
        An Table of states for the available commands.

    Notes:
    ------
    This function just exists to make this easy to cache.
    """
    states, rltt = get_states(backstop_file, state_keys=["pcad_mode"])
    return states, rltt


def get_states(backstop_file, state_keys=None):
    """
    Get the kadi commands states for given backstop file.

    Parameters
    ----------
    backstop_file : str
        The path to the backstop file.
    state_keys : list, optional
        A list of state keys to filter the states. Defaults to None.

    Returns
    -------
    tuple
        A tuple containing (states, rltt)
        states : astropy Table
            An Table of states for the available commands.
        rltt : float
            The running load termination time from backstop file or first command time.
    """
    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)
    rltt = bs_cmds.get_rltt() or bs_cmds["date"][0]

    # Scheduled stop time is the end of propagation, either the explicit
    # time as a pseudo-command in the loads or the last backstop command time.
    sched_stop = bs_cmds.get_scheduled_stop_time() or bs_cmds["date"][-1]

    # Get the states for available commands.  This automatically gets continuity.
    out = kadi_states.get_states(
        cmds=bs_cmds,
        start=rltt,
        stop=sched_stop,
        state_keys=state_keys,
        merge_identical=True,
    )
    return out, rltt


@lru_cache
def calc_man_angle_for_duration(duration):
    """
    Calculate the maneuver-equivalent-angle for a given duration.

    Parameters
    ----------
    duration : float
        The duration for which the maneuver-equivalent-angle needs to be calculated.

    Returns
    -------
    float
        The maneuver-equivalent-angle corresponding to the given duration.
    """
    man_table = make_man_table()
    out = np.interp(duration, man_table["duration"], man_table["angle"])
    return out


def check_continuity_state_npnt(backstop_file):
    """
    Check that the kadi continuity state (at RLTT) is NPNT.

    Parameters
    ----------
    backstop_file : str
        The path to the backstop file.

    Returns
    -------
    bool
        True if the kadi continuity state is NPNT, 0 otherwise.
    """
    _, rltt = get_pcad_states(backstop_file)
    continuity_state = kadi_states.get_continuity(rltt, state_keys=["pcad_mode"])
    if continuity_state["pcad_mode"] != "NPNT":
        return False
    return True


def get_obs_man_angle(npnt_tstart, backstop_file):
    """
    For the dwell that starts at npnt_tstart, get the maneuver-equivalent-angle
    that corresponds to the NMAN time before the dwell start.

    Parameters
    ----------
    npnt_tstart : float
        Start time of the NPNT dwell.
    backstop_file : str
        Backstop file.

    Returns
    -------
    dict
        with key 'angle' value float equivalent maneuver angle between 0 and 180.
        optional key 'warn' value string warning message if there is an issue.
    """
    states, _ = get_pcad_states(backstop_file)
    nman_states = states[states["pcad_mode"] == "NMAN"]
    idx = np.argmin(np.abs(CxoTime(npnt_tstart).secs - nman_states["tstop"]))
    prev_state = nman_states[idx]

    # If there is an issue with lining up an NMAN state with the beginning of an
    # NPNT interval, use 180 as angle and pass a warning back to Perl.
    if np.abs(CxoTime(npnt_tstart).secs - prev_state["tstop"]) > 600:
        warn = f"Maneuver angle err - no manvr ends within 600s of {CxoTime(npnt_tstart).date}\n"
        return {"angle": 180, "warn": warn}
    dur = prev_state["tstop"] - prev_state["tstart"]
    angle = calc_man_angle_for_duration(dur)
    return {"angle": angle}


def ir_zone_ok(backstop_file, out=None):
    """
    Check that the high IR zone is all in NMM.

    Parameters
    ----------
    backstop_file : str
        The path to the backstop file.
    out : str, optional
        The path to the output file for the plain text report.

    Returns
    -------
    bool
        True if the high IR zone time is all in NMM, False otherwise.
    """

    states, _ = get_pcad_states(backstop_file)
    bs_cmds = kadi_commands.get_cmds_from_backstop(backstop_file)

    perigee_cmds = bs_cmds[
        (bs_cmds["type"] == "ORBPOINT") & (bs_cmds["event_type"] == "EPERIGEE")
    ]

    all_ok = True
    out_text = ["IR ZONE CHECKING"]
    for perigee_time in perigee_cmds["time"]:
        # High IR zone is from zone_minus_mins before perigee to zone_plus_mins after perigee
        zone_minus_mins = 10
        zone_plus_mins = 35
        ir_zone_start = perigee_time - (zone_minus_mins * 60)
        ir_zone_stop = perigee_time + (zone_plus_mins * 60)
        out_text.append(
            "Checking perigee states at "
            f"{CxoTime(perigee_time).date} (delta times relative to perigee)"
        )
        out_text.append(
            f"  High IR zone req't: NMAN: -{zone_minus_mins}m to {zone_plus_mins}m "
            f"({CxoTime(ir_zone_start).date} to {CxoTime(ir_zone_stop).date}"
        )
        ok = (states["tstart"] <= ir_zone_stop) & (states["tstop"] >= ir_zone_start)
        for state in states[ok]:
            start_dtime_min = (state["tstart"] - perigee_time) / 60.0
            stop_dtime_min = (state["tstop"] - perigee_time) / 60.0
            ok_status = "  [OK]" if state["pcad_mode"] == "NMAN" else "  [NOT OK]"
            out_text.append(
                f"{ok_status} {state['pcad_mode']}: {start_dtime_min:.1f}m to {stop_dtime_min:.1f}m "
                f"({CxoTime(state['tstart']).date} to {CxoTime(state['tstop']).date})"
            )
        if np.any(states["pcad_mode"][ok] != "NMAN"):
            all_ok = False

    if out is not None:
        with open(out, "w") as fh:
            fh.writelines("\n".join(out_text))

    return all_ok
