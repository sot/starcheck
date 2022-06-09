import pickle
from pathlib import Path
import gzip
import numpy as np
from astropy.table import Table

from starcheck.utils import time2date, date2time, de_bytestr # noqa
from mica.archive import aca_dark
from chandra_aca.star_probs import guide_count, mag_for_p_acq
from chandra_aca.transform import (yagzag_to_pixels, pixels_to_yagzag,
                                   mag_to_count_rate)
import Quaternion
from Ska.quatutil import radec2yagzag
import agasc
from proseco.core import ACABox
from proseco.catalog import get_effective_t_ccd, get_aca_catalog
from proseco.guide import get_imposter_mags
import proseco.characteristics as char

import mica.stats.acq_stats
import mica.stats.guide_stats

ACQS = mica.stats.acq_stats.get_stats()
GUIDES = mica.stats.guide_stats.get_stats()


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
    Return a list of info to make warnings on guide stars or fid
    lights with local dark map that gives an 'imposter_mag' that could
    perturb a centroid.  The potential worst-case offsets (ignoring
    effects at the background pixels) are returned and checking
    against offset limits needs to be done from calling code.

    This fetches the dark current before the date of the observation
    and passes it to proseco.get_imposter_mags with the star candidate
    positions to fetch the brightest 2x2 for each and calculates the
    mag for that region.  The worse case offset is then added to an
    entry for the star index.

    :param idxs: catalog indexes as list or array
    :param yags: catalog yangs as list or array
    :param zags: catalog zangs as list or array
    :param mags: catalog mags (AGASC mags for stars estimated fid mags for fids) list or array
    :param types: catalog TYPE (ACQ|BOT|FID|MON|GUI) as list or array
    :param t_ccd: observation t_ccd in deg C (should be max t_ccd in guide phase)
    :param date: observation date (bytestring via Inline)
    :param dither_y: dither_y in arcsecs (guide dither)
    :param dither_z: dither_z in arcsecs (guide dither)
    :param yellow_lim: yellow limit centroid offset threshold limit (in arcsecs)
    :param red_lim: red limit centroid offset threshold limit (in arcsecs)
    :return imposters: list of dictionaries with keys that define the index, the imposter mag,
             a 'status' key that has value 0 if the code to get the imposter mag ran successfully,
             calculated centroid offset, and star or fid info to make a warning.

    """

    types = [t.decode('ascii') for t in types]
    date = date.decode('ascii')
    eff_t_ccd = get_effective_t_ccd(t_ccd)

    dark = aca_dark.get_dark_cal_image(date=date, t_ccd_ref=eff_t_ccd, aca_image=True)

    def imposter_offset(cand_mag, imposter_mag):
        """
        For a given candidate star and the pseudomagnitude of the
        brightest 2x2 imposter calculate the max offset of the
        imposter counts are at the edge of the 6x6 (as if they were in
        one pixel).  This is somewhat the inverse of
        proseco.get_pixmag_for_offset

        """
        cand_counts = mag_to_count_rate(cand_mag)
        spoil_counts = mag_to_count_rate(imposter_mag)
        return spoil_counts * 3 * 5 / (spoil_counts + cand_counts)

    imposters = []
    for idx, yag, zag, mag, ctype in zip(idxs, yags, zags, mags, types):
        if ctype in ['BOT', 'GUI', 'FID']:
            if ctype in ['BOT', 'GUI']:
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
                entries = Table([{'idx': idx, 'row': row, 'col': col, 'mag': mag, 'type': ctype}])
                imp_mags, imp_rows, imp_cols = get_imposter_mags(entries, dark, dither)
                offset = imposter_offset(mag, imp_mags[0])
                imposters.append({'idx': int(idx), 'status': int(0),
                                  'entry_row': float(row), 'entry_col': float(col),
                                  'bad2_row': float(imp_rows[0]), 'bad2_col': float(imp_cols[0]),
                                  'bad2_mag': float(imp_mags[0]), 'offset': float(offset)})
            except Exception:
                imposters.append({'idx': int(idx), 'status': int(1)})
    return imposters


def _get_agasc_stars(ra, dec, roll, radius, date, agasc_file):
    """
    Fetch the cone of agasc stars.  Update the table with the yag and zag of each star.
    Return as a dictionary with the agasc ids as keys and all of the values as
    simple Python types (int, float)
    """
    stars = agasc.get_agasc_cone(float(ra), float(dec), float(radius), date.decode('ascii'),
                                 agasc_file.decode('ascii'))
    q_aca = Quaternion.Quat([float(ra), float(dec), float(roll)])
    yags, zags = radec2yagzag(stars['RA_PMCORR'], stars['DEC_PMCORR'], q_aca)
    yags *= 3600
    zags *= 3600
    stars['yang'] = yags
    stars['zang'] = zags

    # Get a dictionary of the stars with the columns that are used
    # This needs to be de-numpy-ified to pass back into Perl
    stars_dict = {}
    for star in stars:
        stars_dict[str(star['AGASC_ID'])] = {
            'id': int(star['AGASC_ID']),
            'class': int(star['CLASS']),
            'ra': float(star['RA_PMCORR']),
            'dec': float(star['DEC_PMCORR']),
            'mag_aca': float(star['MAG_ACA']),
            'bv': float(star['COLOR1']),
            'color1': float(star['COLOR1']),
            'mag_aca_err': float(star['MAG_ACA_ERR']),
            'poserr': float(star['POS_ERR']),
            'yag': float(star['yang']),
            'zag': float(star['zang']),
            'aspq': int(star['ASPQ1']),
            'var': int(star['VAR']),
            'aspq1': int(star['ASPQ1'])}

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

    acqs = Table(ACQS[(ACQS['agasc_id'] == agasc_id)
                 & (ACQS['guide_tstart'] < time)])
    ok = acqs['img_func'] == 'star'
    guides = Table(GUIDES[(GUIDES['agasc_id'] == agasc_id)
                          & (GUIDES['kalman_tstart'] < time)])
    mags = np.concatenate(
        [acqs['mag_obs'][acqs['mag_obs'] != 0],
         guides['aoacmag_mean'][guides['aoacmag_mean'] != 0]])

    avg_mag = float(np.mean(mags)) if (len(mags) > 0) else float(13.94)
    stats = {'acq': len(acqs),
             'acq_noid': int(np.count_nonzero(~ok)),
             'gui': len(guides),
             'gui_bad': int(np.count_nonzero(guides['f_track'] < .95)),
             'gui_fail': int(np.count_nonzero(guides['f_track'] < .01)),
             'gui_obc_bad': int(np.count_nonzero(guides['f_obc_bad'] > .05)),
             'avg_mag': avg_mag}
    return stats


def make_proseco_catalog(kwargs):
    """
    Call proseco's get_aca_catalog with the parameters supplied in
    `kwargs` for a specific obsid catalog.  `kwargs` will be a Perl
    hash converted to dict (by Inline) of the expected keyword
    params. These keys must be defined:

    'obsid' obsid
    'att' the target quaternion
    'date' observation date (in Chandra.Time compatible format)
    'n_acq' number of acquisition stars
    'n_guide' number of guide stars
    'man_angle' the maneuver angle to the target quaternion in degrees.
    'include_ids_acq' list of acq star ids
    'include_halfws_acq' list of acq star halfwidths in arcsecs
    'include_ids_guide' list of guide star ids
    'include_ids_fid' list of fid ids
    'dither_acq' acquisition dither
    'dither_guide' guide dither
    't_ccd_acq' acquisition temperature in deg C
    't_ccd_guide' guide temperature in dec C
    'detector' science detector
    'sim_offset' SIM offset

    As these values are from a Perl hash, bytestrings will be
    converted by de_bytestr early in this method.

    :param kwargs: dict of expected keywords
    :return tuple: (list of floats of star acq probabilties, float P2, float expected acq stars)

    """

    kw = de_bytestr(kwargs)

    # Note that the fid ids in starcheck are 1-6
    # ACIS, 7-10 HRC-I 11-14 HRC-S.  Proseco just uses indexes 1-6 so
    # subtract off the offsets.
    fid_ids = np.array(kw['fid_ids'])
    if kw['detector'] == 'HRC-I':
        fid_offset = 6
    elif kw['detector'] == 'HRC-S':
        fid_offset = 10
    else:
        fid_offset = 0
    fid_ids -= fid_offset

    args = dict(obsid=int(kw['obsid']),
                att=Quaternion.normalize(kw['att']),
                date=kw['date'],
                n_acq=kw['n_acq'],
                n_guide=kw['n_guide'],
                man_angle=kw['man_angle'],
                t_ccd_acq=kw['t_ccd_acq'],
                t_ccd_guide=kw['t_ccd_guide'],
                dither_acq=ACABox(kw['dither_acq']),
                dither_guide=ACABox(kw['dither_guide']),
                include_ids_acq=kw['include_ids_acq'],
                include_halfws_acq=kw['include_halfws_acq'],
                detector=kw['detector'], sim_offset=kw['sim_offset'],
                include_ids_guide=kw['include_ids_guide'],
                include_ids_fid=list(fid_ids),
                n_fid=len(kw['fid_ids']), focus_offset=0)
    if 'monitors' in kw:
        args['monitors'] = kw['monitors']
    aca = get_aca_catalog(**args)
    #import pickle
    #pickle.dump({int(kw['obsid']): aca}, open(f"{kw['date']}.pkl", 'wb'))
    return aca


def proseco_probs(aca, include_ids_acq):
    acq_cat = aca.acqs

    # Assign the proseco probabilities back into an array.
    p_acqs = [float(acq_cat['p_acq'][acq_cat['id'] == acq_id][0]) for acq_id in include_ids_acq]

    return p_acqs, float(-np.log10(acq_cat.calc_p_safe())), float(np.sum(p_acqs))


def run_sparkles(aca):
    acar = aca.get_review_table()
    acar.run_aca_review()
    return {'warn': [w['text'] for w in acar.messages == 'critical'],
            'orange_warn': [w['text'] for w in acar.messages == 'caution'],
            'yellow_warn': [w['text'] for w in acar.messages == 'warning'],
            'fyi': [w['text'] for w in acar.messages == 'info']}


def _mag_for_p_acq(p_acq, date, t_ccd):
    """
    Call mag_for_p_acq, but cast p_acq and t_ccd as floats (may or may not be needed) and
    convert date from a bytestring (from the Perl interface).
    """
    eff_t_ccd = get_effective_t_ccd(t_ccd)
    return mag_for_p_acq(float(p_acq), date.decode(), float(eff_t_ccd))


def manual_stars(obsid, proseco_file):
    """
    Get the manual include/excludes from the products pickle to display.
    """
    pth = Path(de_bytestr(proseco_file))
    open_func = open if pth.suffix == '.pkl' else gzip.open
    manual_entries = []
    with open_func(pth, 'rb') as fh:
        acas_dict = pickle.load(fh)
        aca = acas_dict[obsid]
        call_args = aca.call_args.copy()
        for key in call_args:
            if key.startswith('include') or key.startswith('exclude'):
                manual_entries.append(f'has {key} {call_args[key]}\n')
    return manual_entries


def compare_cats(cat1, cat2, type=None):

    check_cols = ['id', 'type', 'halfw',
                  'p_acq', 'mag', 'maxmag', 'yang', 'zang']
    if type == 'gui':
        check_cols.extend(['res'])
    if type == 'mon':
        check_cols.extend(['dim'])

    diffs = []
    if len(cat1) != len(cat2):
        diffs.append(f"Mismatch in number of rows in constructed and products {type} catalog")

    for id in set(cat1['id']) - set(cat2['id']):
        diffs.append(f"Products catalog no {type} entry for id {id}")

    for id in set(cat2['id']) - set(cat1['id']):
        diffs.append(f"Constructed catalog no {type} entry for id {id}")

    for id in cat1['id']:
        if id not in cat2['id']:
            continue
        a = cat1.get_id(id, mon=(type=='mon'))
        b = cat2.get_id(id, mon=(type=='mon'))

        for col in check_cols:
            if isinstance(a[col], float):
                if not np.isclose(a[col], b[col], atol=.1, rtol=0):
                    diffs.append(f"{col} a[col] {a[col]:.2f} != b[col] {b[col]:.2f}")
            else:
                if not a[col] == b[col]:
                    diffs.append(f"{col} a[col] {a[col]} != b[col] {b[col]}")
    return diffs


def compare_prosecos(aca, pfile):

    diffs = []

    pfile_acas = pickle.load(gzip.open(pfile))
    if aca.obsid not in pfile_acas:
        diffs = [f"obsid {aca.obsid} not in {pfile}"]
        return diffs

    # Where 'aca' is the proseco ACATable constructed in starcheck and prod_aca
    # is the table packaged in the released products.
    prod_aca = pfile_acas[aca.obsid]

    # Check temperatures
    if not np.isclose(aca.t_ccd_acq, prod_aca.t_ccd_acq, rtol=0, atol=1):
        diffs.append(f"Acq t_ccd starcheck {aca.t_ccd_acq:.1f} products pkl {prod_aca.t_ccd_acq:.1f}")

    if not np.isclose(aca.t_ccd_guide, prod_aca.t_ccd_guide, rtol=0, atol=1):
        diffs.append(
            f"Guide/Max t_ccd starcheck {aca.t_ccd_guide:.1f} products pkl {prod_aca.t_ccd_guide:.1f}")

    # Check acquisition catalog
    ok1 = np.in1d(aca['type'], ['ACQ', 'BOT'])
    ok2 = np.in1d(prod_aca['type'], ['ACQ', 'BOT'])
    diffs.extend(compare_cats(aca[ok1], prod_aca[ok2], 'acq'))

    # Check guide catalog
    ok1 = np.in1d(aca['type'], ['GUI', 'BOT'])
    ok2 = np.in1d(prod_aca['type'], ['GUI', 'BOT'])
    diffs.extend(compare_cats(aca[ok1], prod_aca[ok2], 'gui'))

    # Check fid catalog
    ok1 = np.in1d(aca['type'], ['FID'])
    ok2 = np.in1d(prod_aca['type'], ['FID'])
    diffs.extend(compare_cats(aca[ok1], prod_aca[ok2], 'fid'))

    # Check mon catalog
    ok1 = np.in1d(aca['type'], ['MON'])
    ok2 = np.in1d(prod_aca['type'], ['MON'])
    diffs.extend(compare_cats(aca[ok1], prod_aca[ok2], 'mon'))

    return diffs
