import logging
import os
from pathlib import Path

import agasc
import cxotime
import mica.stats.acq_stats
import mica.stats.guide_stats
import numpy as np
import proseco.characteristics as proseco_char
import proseco.characteristics as char
import Quaternion
from astropy.table import Table
from Chandra.Time import DateTime
from chandra_aca.star_probs import guide_count, mag_for_p_acq
from chandra_aca.transform import mag_to_count_rate, pixels_to_yagzag, yagzag_to_pixels
from kadi.commands import states
from mica.archive import aca_dark
from proseco.catalog import get_aca_catalog, get_effective_t_ccd
from proseco.core import ACABox
from proseco.guide import get_imposter_mags
from Ska.quatutil import radec2yagzag
from testr import test_helper

import starcheck
from starcheck import __version__ as version
from starcheck.calc_ccd_temps import get_ccd_temps
from starcheck.check_ir_zone import ir_zone_ok
from starcheck.pcad_att_check import make_pcad_attitude_check_report
from starcheck.plot import make_plots_for_obsid

ACQS = mica.stats.acq_stats.get_stats()
GUIDES = mica.stats.guide_stats.get_stats()


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


def ccd_temp_wrapper(**kwargs):
    return get_ccd_temps(**kwargs)


def plot_cat_wrapper(**kwargs):
    return make_plots_for_obsid(**kwargs)


def starcheck_version():
    return version


def get_chandra_models_version():
    return proseco_char.chandra_models_version


def set_kadi_scenario_default():
    # For kadi commands v2 running on HEAD set the default scenario to flight.
    # This is aimed at running in production where the commands archive is
    # updated hourly. In this case no network resources are used.
    if test_helper.on_head_network():
        os.environ.setdefault("KADI_SCENARIO", "flight")


def get_cheta_source():
    sources = starcheck.calc_ccd_temps.fetch.data_source.sources()
    if len(sources) == 1 and sources[0] == "cxc":
        return "cxc"
    else:
        return str(sources)


def get_kadi_scenario():
    return os.getenv("KADI_SCENARIO", default="None")


def get_data_dir():
    sc_data = os.path.join(os.path.dirname(starcheck.__file__), "data")
    return sc_data if os.path.exists(sc_data) else ""


def _make_pcad_attitude_check_report(**kwargs):
    return make_pcad_attitude_check_report(**kwargs)


def make_ir_check_report(**kwargs):
    return ir_zone_ok(**kwargs)


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


def _get_aca_limits():
    return float(char.aca_t_ccd_planning_limit), float(char.aca_t_ccd_penalty_limit)


def _pixels_to_yagzag(i, j):
    """
    Call chandra_aca.transform.pixels_to_yagzag.
    This wrapper is set to pass allow_bad=True, as exceptions from the Python side
    in this case would not be helpful, and the very small bad pixel list should be
    on the CCD.
    :params i: pixel row
    :params j: pixel col
    :returns tuple: yag, zag as floats
    """
    yag, zag = pixels_to_yagzag(i, j, allow_bad=True)
    return float(yag), float(zag)


def _yagzag_to_pixels(yag, zag):
    """
    Call chandra_aca.transform.yagzag_to_pixels.
    This wrapper is set to pass allow_bad=True, as exceptions from the Python side
    in this case would not be helpful, and the boundary checks and such will work fine
    on the Perl side even if the returned row/col is off the CCD.
    :params yag: y-angle arcsecs (hopefully as a number from the Perl)
    :params zag: z-angle arcsecs (hopefully as a number from the Perl)
    :returns tuple: row, col as floats
    """
    row, col = yagzag_to_pixels(yag, zag, allow_bad=True)
    return float(row), float(col)


def _guide_count(mags, t_ccd, count_9th=False):
    eff_t_ccd = get_effective_t_ccd(t_ccd)
    return float(guide_count(np.array(mags), eff_t_ccd, count_9th))


def check_hot_pix(idxs, yags, zags, mags, types, t_ccd, date, dither_y, dither_z):
    """
    Return a list of info to make warnings on guide stars or fid lights with
    local dark map that gives an 'imposter_mag' that could perturb a centroid.
    The potential worst-case offsets (ignoring effects at the background pixels)
    are returned and checking against offset limits needs to be done from
    calling code.

    This fetches the dark current before the date of the observation and passes
    it to proseco.get_imposter_mags with the star candidate positions to fetch
    the brightest 2x2 for each and calculates the mag for that region.  The
    worse case offset is then added to an entry for the star index.

    :param idxs: catalog indexes as list or array
    :param yags: catalog yangs as list or array
    :param zags: catalog zangs as list or array
    :param mags: catalog mags (AGASC mags for stars estimated fid mags for fids)
        list or array
    :param types: catalog TYPE (ACQ|BOT|FID|MON|GUI) as list or array
    :param t_ccd: observation t_ccd in deg C (should be max t_ccd in guide
        phase)
    :param date: observation date (str)
    :param dither_y: dither_y in arcsecs (guide dither)
    :param dither_z: dither_z in arcsecs (guide dither)
    :param yellow_lim: yellow limit centroid offset threshold limit (in arcsecs)
    :param red_lim: red limit centroid offset threshold limit (in arcsecs)
    :return imposters: list of dictionaries with keys that define the index, the
             imposter mag, a 'status' key that has value 0 if the code to get
             the imposter mag ran successfully, calculated centroid offset, and
             star or fid info to make a warning.
    """

    eff_t_ccd = get_effective_t_ccd(t_ccd)

    dark = aca_dark.get_dark_cal_image(date=date, t_ccd_ref=eff_t_ccd, aca_image=True)

    def imposter_offset(cand_mag, imposter_mag):
        """
        For a given candidate star and the pseudomagnitude of the brightest 2x2
        imposter calculate the max offset of the imposter counts are at the edge
        of the 6x6 (as if they were in one pixel).  This is somewhat the inverse
        of proseco.get_pixmag_for_offset
        """
        cand_counts = mag_to_count_rate(cand_mag)
        spoil_counts = mag_to_count_rate(imposter_mag)
        return spoil_counts * 3 * 5 / (spoil_counts + cand_counts)

    imposters = []
    for idx, yag, zag, mag, ctype in zip(idxs, yags, zags, mags, types):
        if ctype in ["BOT", "GUI", "FID"]:
            if ctype in ["BOT", "GUI"]:
                dither = ACABox((dither_y, dither_z))
            else:
                dither = ACABox((5.0, 5.0))
            row, col = yagzag_to_pixels(yag, zag, allow_bad=True)
            # Handle any errors in get_imposter_mags with a try/except.  This doesn't
            # try to pass back a message.  Most likely this will only fail if the star
            # or fid is completely off the CCD and will have other warning.
            try:
                # get_imposter_mags takes a Table of candidates as its first argument, so construct
                # a single-candidate table `entries`
                entries = Table(
                    [{"idx": idx, "row": row, "col": col, "mag": mag, "type": ctype}]
                )
                imp_mags, imp_rows, imp_cols = get_imposter_mags(entries, dark, dither)
                offset = imposter_offset(mag, imp_mags[0])
                imposters.append(
                    {
                        "idx": int(idx),
                        "status": int(0),
                        "entry_row": float(row),
                        "entry_col": float(col),
                        "bad2_row": float(imp_rows[0]),
                        "bad2_col": float(imp_cols[0]),
                        "bad2_mag": float(imp_mags[0]),
                        "offset": float(offset),
                    }
                )
            except Exception:
                imposters.append({"idx": int(idx), "status": int(1)})
    return imposters


def _get_agasc_stars(ra, dec, roll, radius, date, agasc_file):
    """
    Fetch the cone of agasc stars.  Update the table with the yag and zag of each star.
    Return as a dictionary with the agasc ids as keys and all of the values as
    simple Python types (int, float)
    """
    stars = agasc.get_agasc_cone(
        float(ra),
        float(dec),
        float(radius),
        date,
        agasc_file,
    )
    q_aca = Quaternion.Quat([float(ra), float(dec), float(roll)])
    yags, zags = radec2yagzag(stars["RA_PMCORR"], stars["DEC_PMCORR"], q_aca)
    yags *= 3600
    zags *= 3600
    stars["yang"] = yags
    stars["zang"] = zags

    # Get a dictionary of the stars with the columns that are used
    # This needs to be de-numpy-ified to pass back into Perl
    stars_dict = {}
    for star in stars:
        stars_dict[str(star["AGASC_ID"])] = {
            "id": int(star["AGASC_ID"]),
            "class": int(star["CLASS"]),
            "ra": float(star["RA_PMCORR"]),
            "dec": float(star["DEC_PMCORR"]),
            "mag_aca": float(star["MAG_ACA"]),
            "bv": float(star["COLOR1"]),
            "color1": float(star["COLOR1"]),
            "mag_aca_err": float(star["MAG_ACA_ERR"]),
            "poserr": float(star["POS_ERR"]),
            "yag": float(star["yang"]),
            "zag": float(star["zang"]),
            "aspq": int(star["ASPQ1"]),
            "var": int(star["VAR"]),
            "aspq1": int(star["ASPQ1"]),
        }

    return stars_dict


def get_mica_star_stats(agasc_id, time):
    """
    Get the acq and guide star statistics for a star before a given time.
    The time filter is just there to make this play well when run in regression.
    The mica acq and guide stats are fetched into globals ACQS and GUIDES
    and this method just filters for the relevant ones for a star and returns
    a dictionary of summarized statistics.

    :param agasc_id: agasc id of star
    :param time: time used as end of range to retrieve statistics.

    :return: dictionary of stats for the observed history of the star
    """

    # Cast the inputs
    time = float(time)
    agasc_id = int(agasc_id)

    acqs = Table(ACQS[(ACQS["agasc_id"] == agasc_id) & (ACQS["guide_tstart"] < time)])
    ok = acqs["img_func"] == "star"
    guides = Table(
        GUIDES[(GUIDES["agasc_id"] == agasc_id) & (GUIDES["kalman_tstart"] < time)]
    )
    mags = np.concatenate(
        [
            acqs["mag_obs"][acqs["mag_obs"] != 0],
            guides["aoacmag_mean"][guides["aoacmag_mean"] != 0],
        ]
    )

    avg_mag = float(np.mean(mags)) if (len(mags) > 0) else float(13.94)
    stats = {
        "acq": len(acqs),
        "acq_noid": int(np.count_nonzero(~ok)),
        "gui": len(guides),
        "gui_bad": int(np.count_nonzero(guides["f_track"] < 0.95)),
        "gui_fail": int(np.count_nonzero(guides["f_track"] < 0.01)),
        "gui_obc_bad": int(np.count_nonzero(guides["f_obc_bad"] > 0.05)),
        "avg_mag": avg_mag,
    }
    return stats


def _mag_for_p_acq(p_acq, date, t_ccd):
    """
    Call mag_for_p_acq, but cast p_acq and t_ccd as floats.
    """
    eff_t_ccd = get_effective_t_ccd(t_ccd)
    return mag_for_p_acq(float(p_acq), date, float(eff_t_ccd))


def proseco_probs(**kw):
    """
    Call proseco's get_acq_catalog with the parameters supplied in `kwargs` for
    a specific obsid catalog and return the individual acq star probabilities,
    the P2 value for the catalog, and the expected number of acq stars.

    `kwargs` will be a Perl hash converted to dict (by Inline) of the expected
    keyword params. These keys must be defined:

    'q1', 'q2', 'q3', 'q4' = the target quaternion 'man_angle' the maneuver
    angle to the target quaternion in degrees. 'acq_ids' list of acq star ids
    'halfwidths' list of acq star halfwidths in arcsecs 't_ccd_acq' acquisition
    temperature in deg C 'date' observation date (in Chandra.Time compatible
    format) 'detector' science detector 'sim_offset' SIM offset

    As these values are from a Perl hash, bytestrings will be converted by
    de_bytestr early in this method.

    :param **kw: dict of expected keywords
    :return tuple: (list of floats of star acq probabilties, float P2, float
        expected acq stars)

    """

    args = dict(
        obsid=0,
        att=Quaternion.normalize(kw["att"]),
        date=kw["date"],
        n_acq=kw["n_acq"],
        man_angle=kw["man_angle"],
        t_ccd_acq=kw["t_ccd_acq"],
        t_ccd_guide=kw["t_ccd_guide"],
        dither_acq=ACABox(kw["dither_acq"]),
        dither_guide=ACABox(kw["dither_guide"]),
        include_ids_acq=kw["include_ids_acq"],
        include_halfws_acq=kw["include_halfws_acq"],
        detector=kw["detector"],
        sim_offset=kw["sim_offset"],
        n_fid=0,
        n_guide=0,
        focus_offset=0,
    )
    aca = get_aca_catalog(**args)
    acq_cat = aca.acqs

    # Assign the proseco probabilities back into an array.
    p_acqs = [
        float(acq_cat["p_acq"][acq_cat["id"] == acq_id][0])
        for acq_id in kw["include_ids_acq"]
    ]

    return p_acqs, float(-np.log10(acq_cat.calc_p_safe())), float(np.sum(p_acqs))
