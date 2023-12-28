import logging
import os
from pathlib import Path
import warnings

import agasc
import cxotime
import mica.stats.acq_stats
import mica.stats.guide_stats
import numpy as np
import Quaternion
from astropy.table import Table
from Chandra.Time import DateTime
from chandra_aca.star_probs import mag_for_p_acq
import chandra_aca.star_probs
from chandra_aca.dark_model import dark_temp_scale
from chandra_aca.drift import get_fid_offset
import sparkles
from chandra_aca.transform import mag_to_count_rate, pixels_to_yagzag, yagzag_to_pixels
from mica.archive import aca_dark
from parse_cm import read_backstop_as_list, write_backstop
from proseco.catalog import get_aca_catalog, get_effective_t_ccd
from proseco.core import ACABox
from proseco.guide import get_imposter_mags
from Ska.quatutil import radec2yagzag
from testr import test_helper
from cxotime import CxoTime

import kadi.commands.states as kadi_states

import starcheck
from starcheck import __version__ as version
from starcheck.calc_ccd_temps import get_ccd_temps
from starcheck.state_checks import ir_zone_ok
from starcheck.plot import make_plots_for_obsid

ACQS = mica.stats.acq_stats.get_stats()
GUIDES = mica.stats.guide_stats.get_stats()

# Ignore warnings about clipping the acquisition model magnitudes
# from chandra_aca.star_probs
warnings.filterwarnings(
    "ignore",
    category=UserWarning,
    message=r"\nModel .* computed between .* clipping input mag\(s\) outside that range\.",
)


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
    state = kadi_states.get_continuity(date, cols)
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
    # Convert to lists or floats to avoid numpy types which are not JSON serializable
    return yag.tolist(), zag.tolist()


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
    # Convert to lists or floats to avoid numpy types which are not JSON serializable
    return row.tolist(), col.tolist()


def apply_t_ccds_bonus(mags, t_ccd, date):
    """
    Calculate the dynamic background bonus temperatures for a given set of
    magnitudes, t_ccd (which should be the effective t_ccd with any penalty applied),
    and date. This applies values of dyn_bgd_n_faint and dyn_bgd_dt_ccd.
    This calls chandra_aca.sparkles.get_t_ccds_bonus.

    :param mags: list of magnitudes
    :param t_ccd: effective t_ccd
    :param date: date. Used to determine default value of dyn_bgd_n_faint and set
                 dyn_bgd_n_faint to 2 after PEA patch uplink and activation on 2023:139.
    :returns: list of dynamic background bonus temperatures (degC) in the order of mags
    """
    dyn_bgd_dt_ccd = -4.0
    # Set dyn_bgd_n_faint to 2 after PEA patch uplink and activation on 2023:139
    dyn_bgd_n_faint = 2 if CxoTime(date).date >= "2023:139" else 0
    return sparkles.get_t_ccds_bonus(mags, t_ccd, dyn_bgd_n_faint, dyn_bgd_dt_ccd)


def guide_count(mags, t_ccd, count_9th, date):
    """
    Return the fractional guide_count for a given set of magnitudes, estimated
    t_ccd, count_9th (bool or 0 or 1), and date. This determines the effective
    t_ccd, applies any dynamic background bonus, and then calls
    chandra_aca.star_probs.guide_count.

    :param mags: list of magnitudes
    :param t_ccd: estimated t_ccd from thermal model (this function applies any
                  penalty, so input t_ccd should not have penalty applied)
    :param count_9th: bool or 0 or 1 for whether to use count_9th mode
    :param date: date of observation
    :returns: fractional guide_count as float
    """
    eff_t_ccd = get_effective_t_ccd(t_ccd)
    t_ccds_bonus = apply_t_ccds_bonus(mags, eff_t_ccd, date)
    return float(
        chandra_aca.star_probs.guide_count(np.array(mags), t_ccds_bonus, count_9th)
    )


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
    :return imposters: list of dictionaries with keys that define the index, the
             imposter mag, a 'status' key that has value 0 if the code to get
             the imposter mag ran successfully, calculated centroid offset, and
             star or fid info to make a warning.
    """

    dark_props = aca_dark.get_dark_cal_props(
        date=date, include_image=True, aca_image=True
    )
    dark = dark_props["image"]
    dark_t_ccd = dark_props["ccd_temp"]

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

    # Get the effective t_ccd for use for the fid lights and some guide stars.
    eff_t_ccd = get_effective_t_ccd(t_ccd)

    # Get the t_ccd bonus for n=dyn_bgd_n_faint of the guide stars.
    guide_mags = []
    guide_idxs = []
    for idx, mag, ctype in zip(idxs, mags, types):
        if ctype in ["BOT", "GUI"]:
            guide_mags.append(mag)
            guide_idxs.append(idx)
    guide_t_ccds = apply_t_ccds_bonus(guide_mags, eff_t_ccd, date)
    guide_t_ccd_dict = dict(zip(guide_idxs, guide_t_ccds))

    imposters = []
    for idx, yag, zag, mag, ctype in zip(idxs, yags, zags, mags, types):
        if ctype in ["BOT", "GUI", "FID"]:
            if ctype in ["BOT", "GUI"]:
                t_ccd = guide_t_ccd_dict[idx]
                dither = ACABox((dither_y, dither_z))
            else:
                t_ccd = eff_t_ccd
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
                scale = dark_temp_scale(dark_t_ccd, t_ccd)
                imp_mags, imp_rows, imp_cols = get_imposter_mags(entries, dark, dither)
                imp_mags, imp_rows, imp_cols = get_imposter_mags(
                    entries, dark * scale, dither
                )
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
                        "t_ccd": float(t_ccd),
                        "dark_date": dark_props["date"],
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

    `kwargs` will be a Perl hash converted to dict of the expected
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


def vehicle_filter_backstop(backstop_file, outfile):
    """
    Filter the backstop file to remove SCS 131, 132, 133 except MP_OBSID commands.
    This is basically equivalent to the vehicle backstop file, but the MP_OBSID
    commands are useful for ACA to associate maneuvers with observations.
    """
    # Use parse_cm read_backstop_as_list instead of kadi.commands.read_backstop
    # as we want the params to keep the SCS to write back later.
    cmds = read_backstop_as_list(backstop_file, inline_params=False)
    # Filter the commands to remove SCS 131, 132, 133 except MP_OBSID commands
    filtered_cmds = [
        cmd for cmd in cmds if cmd["scs"] < 131 or cmd["type"] == "MP_OBSID"
    ]
    # Write the filtered commands to the output file
    write_backstop(filtered_cmds, outfile)
