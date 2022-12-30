import functools
import logging
import os
from pathlib import Path

import cxotime
import numpy as np
import proseco.characteristics as proseco_char
from Chandra.Time import DateTime
from kadi.commands import states
from testr import test_helper

import starcheck
from starcheck import __version__ as version
from starcheck.calc_ccd_temps import get_ccd_temps
from starcheck.check_ir_zone import ir_zone_ok
from starcheck.pcad_att_check import make_pcad_attitude_check_report
from starcheck.plot import make_plots_for_obsid


def date2secs(val):
    """Convert date to seconds since 1998.0"""
    out = cxotime.date2secs(val)
    # if isinstance(out, (np.number, np.ndarray)):
    #     out = out.tolist()
    return out


def secs2date(val):
    """Convert date to seconds since 1998.0"""
    out = cxotime.secs2date(val)
    # if isinstance(out, (np.number, np.ndarray)):
    #    out = out.tolist()
    return out


def date2time(val):
    out = cxotime.date2secs(val)
    if isinstance(out, (np.number, np.ndarray)):
        out = out.tolist()
    return out


def time2date(val):
    out = cxotime.secs2date(val)
    if isinstance(out, (np.number, np.ndarray)):
        out = out.tolist()
    return out


def python_from_perl(func):
    """Decorator to facilitate calling Python from Perl inline.

    - Convert byte strings to unicode.
    - Print stack trace on exceptions which perl inline suppresses.
    """

    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        args = de_bytestr(args)
        kwargs = de_bytestr(kwargs)
        try:
            return func(*args, **kwargs)
        except Exception:
            import traceback

            traceback.print_exc()
            raise

    return wrapper


# Borrowed from https://stackoverflow.com/a/33160507
def de_bytestr(data):
    if isinstance(data, bytes):
        return data.decode()
    if isinstance(data, dict):
        return dict(map(de_bytestr, data.items()))
    if isinstance(data, tuple):
        return tuple(map(de_bytestr, data))
    if isinstance(data, list):
        return list(map(de_bytestr, data))
    if isinstance(data, set):
        return set(map(de_bytestr, data))
    return data


@python_from_perl
def ccd_temp_wrapper(kwargs):
    return get_ccd_temps(**kwargs)


@python_from_perl
def plot_cat_wrapper(kwargs):
    return make_plots_for_obsid(**kwargs)


@python_from_perl
def starcheck_version():
    return version


@python_from_perl
def get_chandra_models_version():
    return proseco_char.chandra_models_version


@python_from_perl
def set_kadi_scenario_default():
    # For kadi commands v2 running on HEAD set the default scenario to flight.
    # This is aimed at running in production where the commands archive is
    # updated hourly. In this case no network resources are used.
    if test_helper.on_head_network():
        os.environ.setdefault("KADI_SCENARIO", "flight")


@python_from_perl
def get_cheta_source():
    sources = starcheck.calc_ccd_temps.fetch.data_source.sources()
    if len(sources) == 1 and sources[0] == "cxc":
        return "cxc"
    else:
        return str(sources)


@python_from_perl
def get_kadi_scenario():
    return os.getenv("KADI_SCENARIO", default="None")


@python_from_perl
def get_data_dir():
    sc_data = os.path.join(os.path.dirname(starcheck.__file__), "data")
    return sc_data if os.path.exists(sc_data) else ""


@python_from_perl
def _make_pcad_attitude_check_report(kwargs):
    return make_pcad_attitude_check_report(**kwargs)


@python_from_perl
def make_ir_check_report(kwargs):
    return ir_zone_ok(**kwargs)


@python_from_perl
def get_dither_kadi_state(date):
    cols = [
        "dither",
        "dither_ampl_pitch",
        "dither_ampl_yaw",
        "dither_period_pitch",
        "dither_period_yaw",
    ]
    state = states.get_continuity(date, cols)
    # Cast the numpy floats as plain floats
    for key in [
        "dither_ampl_pitch",
        "dither_ampl_yaw",
        "dither_period_pitch",
        "dither_period_yaw",
    ]:
        state[key] = float(state[key])
    # get most recent change time
    state["time"] = float(
        np.max([DateTime(state["__dates__"][key]).secs for key in cols])
    )
    return state


@python_from_perl
def get_run_start_time(run_start_time, backstop_start):
    """
    Determine a reasonable reference run start time based on the supplied
    run start time and the time of the first backstop command.  This
    code uses a small hack so that a negative number is interpreted
    as the desired "days back" from the backstop start time.  All other
    Chandra.Time compatible formats for run start are used as absolute
    times (which will then be passed to the thermal model code as the
    time before which telemetry should be found for an initial state).
    Note that the logic to determine the initial state will not allow
    that state to be after backstop start time.

    :param run_start_time: supplied run start time in a Chandra.Time format,
                      empty string interpreted as "now" as expected,
                      negative numbers special cased to be interpreted as
                      "days back" relative to first backstop command.
    :param backstop_start: time of first backstop command
    :returns: YYYY:DOY string of reference run start time
    """

    # For the special case where run_start_time casts as a float
    # check to see if it is negative and if so, set the reference
    # time to be a time run_start_time days back from backstop start
    try:
        run_start_time = float(run_start_time)
    # Handle nominal errors if run_start_time None or non-float Chandra.Time OK string.
    except (TypeError, ValueError):
        ref_time = DateTime(run_start_time)
    else:
        if run_start_time < 0:
            ref_time = DateTime(backstop_start) + run_start_time
        else:
            raise ValueError("Float run_start_time should be negative")
    return ref_time.date


@python_from_perl
def config_logging(outdir, verbose, name):
    """Set up file and console logger.
    See http://docs.python.org/library/logging.html
              #logging-to-multiple-destinations
    """
    # Disable auto-configuration of root logger by adding a null handler.
    # This prevents other modules (e.g. Chandra.cmd_states) from generating
    # a streamhandler by just calling logging.info(..).
    class NullHandler(logging.Handler):
        def emit(self, record):
            pass

    rootlogger = logging.getLogger()
    rootlogger.addHandler(NullHandler())

    loglevel = {0: logging.CRITICAL, 1: logging.INFO, 2: logging.DEBUG}.get(
        int(verbose), logging.INFO
    )

    logger = logging.getLogger(name)
    logger.setLevel(loglevel)

    # Remove existing handlers if this logger is already configured
    for handler in list(logger.handlers):
        logger.removeHandler(handler)

    formatter = logging.Formatter("%(message)s")

    console = logging.StreamHandler()
    console.setFormatter(formatter)
    logger.addHandler(console)

    outdir = Path(outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    filehandler = logging.FileHandler(filename=outdir / "run.dat", mode="w")
    filehandler.setFormatter(formatter)
    logger.addHandler(filehandler)
