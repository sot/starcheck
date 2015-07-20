"""
Functions related to probabilities for star acquisition and guide tracking.
"""

from __future__ import print_function, division

from numba import jit
from itertools import izip

from scipy.optimize import brentq
import numpy as np
from Chandra.Time import DateTime

# Scale and offset fit of polynomial to acq failures in log space.
# Derived in the fit_sota_model_probit.ipynb IPython notebook for data
# covering 2007-Jan-01 - 2015-July-01.  This is in the state_of_aca repo.
#
# scale = scl2 * m10**2 + scl1 * m10 + scl0, where m10 = mag - 10,
# and likewise for offset.


WARM_THRESHOLD = 100  # Value (N100) used for fitting

SOTA_FIT_NO_1P5 = [9.6887121605441173,  # scl0
                   9.1613040261776177,  # scl1
                   -0.41919343599067715,  # scl2
                   -2.3829996965532048,  # off0
                   0.54998934814773903,  # off1
                   0.47839260691599156]  # off2

SOTA_FIT_ONLY_1P5 = [8.541709287866361,
                     0.44482688155644085,
                     -3.5137852251178465,
                     -1.3505424393223699,
                     1.5278061271148755,
                     0.30973569068842272]


def t_ccd_warm_limit(date, mags, colors=0,
                     min_n_acq=5.0,
                     cold_t_ccd=-21,
                     warm_t_ccd=-5):
    """
    Find the warmest CCD temperature at which at least ``min_n_acq`` acquisition stars
    expected.  This returns a value between ``cold_t_ccd`` and ``warm_t_ccd``.  At the
    cold end the result may be below ``min_n_acq``, in which case the star catalog
    may be rejected.

    :param date: observation date (any Chandra.Time valid format)
    :param mags: star ACA mags
    :param colors: star B-V colors
    :param min_n_acq: minimum required expected stars
    :param cold_t_ccd: coldest CCD temperature to consider
    :param warm_t_ccd: warmest CCD temperature to consider

    :returns: (t_ccd, n_acq) tuple with CCD temperature upper limit and number of
              expected ACQ stars at that temperature.
    """

    def n_acq_above_min(t_ccd):
        probs = acq_success_prob(date=date, t_ccd=t_ccd, mag=mags, color=colors)
        return np.sum(probs) - min_n_acq

    if n_acq_above_min(warm_t_ccd) >= 0:
        # If there are enough ACQ stars at the warmest reasonable CCD temperature
        # then use that temperature.
        t_ccd = warm_t_ccd

    elif n_acq_above_min(cold_t_ccd) <= 0:
        # If there are not enough ACQ stars at the coldest CCD temperature then stop there
        # as well.  The ACA thermal model will never predict a temperature below this
        # value so this catalog will fail thermal check.
        t_ccd = cold_t_ccd

    else:
        # At this point there must be a zero in the range [cold_t_ccd, warm_t_ccd]
        t_ccd = brentq(n_acq_above_min, cold_t_ccd, warm_t_ccd, xtol=1e-4, rtol=1e-4)

    n_acq = n_acq_above_min(t_ccd) + min_n_acq

    return t_ccd, n_acq


def mag_for_p_acq(p_acq, date=None, t_ccd=-19.0):
    """
    For a given ``date`` and ``t_ccd``, find the star magnitude that has an
    acquisition probability of ``p_acq``.

    :param p_acq: acquisition probability (0 to 1.0)
    :param date: observation date (any Chandra.Time valid format)
    :param t_ccd: ACA CCD temperature (deg C)

    :returns mag: star magnitude
    """

    def prob_minus_p_acq(mag):
        prob = acq_success_prob(date=date, t_ccd=t_ccd, mag=mag)
        return prob - p_acq

    # prob_minus_p_acq is monotonically decreasing from the (minimum)
    # bright mag to the (maximum) faint_mag.
    bright_mag = 5.0
    faint_mag = 12.0
    if prob_minus_p_acq(bright_mag) <= 0:
        # Below zero already at bright mag limit so return the bright limit.
        mag = bright_mag

    elif prob_minus_p_acq(faint_mag) >= 0:
        # Above zero still at the faint mag limit so return the faint limit.
        mag = faint_mag

    else:
        # At this point there must be a zero in the range [bright_mag, faint_mag]
        mag = brentq(prob_minus_p_acq, bright_mag, faint_mag, xtol=1e-4, rtol=1e-4)

    return mag


@jit(nopython=True)
def _prob_n_acq(star_probs, n_stars, n_acq_probs):
    """
    Jit-able portion of prob_n_acq
    """
    for cfg in range(1 << n_stars):
        prob = 1.0
        n_acq = 0
        for slot in range(n_stars):
            success = cfg & (1 << slot)
            if success > 0:
                prob = prob * star_probs[slot]
                n_acq += 1
            else:
                prob = prob * (1 - star_probs[slot])
        n_acq_probs[n_acq] += prob


def prob_n_acq(star_probs):
    """
    Given an input array of star acquisition probabilities ``star_probs``,
    return the probabilities of acquiring exactly n_acq stars, where n_acq
    is evaluated at values 0 to n_stars.  This is returned as an array
    of length n_stars.  In addition the cumulative sum, which represents
    the probability of acquiring n_acq or fewer stars, is returned.

    :param star_probs: array of star acq probabilities (list or ndarray)

    :returns n_acq_probs, cum_n_acq_probs: tuple of ndarray, ndarray
    """
    star_probs = np.array(star_probs, dtype=np.float64)
    n_stars = len(star_probs)
    n_acq_probs = np.zeros(n_stars + 1, dtype=np.float64)

    _prob_n_acq(star_probs, n_stars, n_acq_probs)

    return n_acq_probs, np.cumsum(n_acq_probs)


def acq_success_prob(date=None, t_ccd=-19.0, mag=10.0, color=0.6, spoiler=False):
    """
    Return probability of acquisition success for given date, temperature and mag.

    Any of the inputs can be scalars or arrays, with the output being the result of
    the broadcasted dimension of the inputs.

    This is based on the dark model and acquisition success model presented
    in the State of the ACA 2013, and subsequently updated to use a Probit
    transform and separately fit B-V=1.5 stars.  This is available in the
    state_of_aca repo as fit_sota_model_probit.ipynb.

    :param date: Date(s) (scalar or np.ndarray, default=NOW)
    :param t_ccd: CD temperature(s) (degC, scalar or np.ndarray, default=-19C)
    :param mag: Star magnitude(s) (scalar or np.ndarray, default=10.0)
    :param color: Star color(s) (scalar or np.ndarray, default=0.6)
    :param spoil: Star spoiled (boolean or np.ndarray, default=False)

    :returns: Acquisition success probability(s)
    """
    from mica.archive.aca_dark.dark_model import get_warm_fracs

    date = DateTime(date).secs

    is_scalar, dates, t_ccds, mags, colors, spoilers = broadcast_arrays(date, t_ccd, mag,
                                                                        color, spoiler)
    spoilers = spoilers.astype(bool)

    warm_fracs = []
    for date, t_ccd in izip(dates.ravel(), t_ccds.ravel()):
        warm_frac = get_warm_fracs(WARM_THRESHOLD, date=date, T_ccd=t_ccd)
        warm_fracs.append(warm_frac)
    warm_frac = np.array(warm_fracs).reshape(dates.shape)

    probs = model_acq_success_prob(mags, warm_fracs, colors)

    p_0p7color = .4294  # probability multiplier for a B-V = 0.700 star (REF?)
    p_spoiler = .9241  # probability multiplier for a search-spoiled star (REF?)

    # If the star is brighter than 8.5 or has a calculated probability
    # higher than the max_star_prob, clip it at that value
    max_star_prob = .985
    probs[mags < 8.5] = max_star_prob
    probs[colors == 0.7] *= p_0p7color
    probs[spoilers] *= p_spoiler
    probs = probs.clip(1e-6, max_star_prob)

    # Return probabilities.  The [()] getitem at the end will flatten a
    # scalar array down to a pure scalar.
    return probs[0] if is_scalar else probs


def model_acq_success_prob(mag, warm_frac, color=0):
    """
    Calculate raw model probability of acquisition success for a star with ``mag``
    magnitude and a CCD warm fraction ``warm_frac``.  This is not typically used directly
    since it does not account for star properties like spoiled or color=0.7.

    Uses the empirical relation::

       P_acq_fail = Normal_CDF(offset(mag) + scale(mag) * warm_frac)
       P_acq_success = 1 - P_acq_fail

    This is based on the dark model and acquisition success model presented
    in the State of the ACA 2013, and subsequently updated to use a Probit
    transform and separately fit B-V=1.5 stars.  This is available in the
    state_of_aca repo as fit_sota_model_probit.ipynb.

    :param mag: ACA magnitude (float or np.ndarray)
    :param warm_frac: N100 warm fraction (float or np.ndarray)
    :param color: B-V color to check for B-V=1.5 => red star (float or np.ndarray)
    """
    from scipy.stats import norm

    is_scalar, mag, warm_frac, color = broadcast_arrays(mag, warm_frac, color)

    m10 = mag - 10.0

    p_fail = np.zeros_like(mag)
    for mask, fit_pars in ((color == 1.5, SOTA_FIT_ONLY_1P5),
                           (color != 1.5, SOTA_FIT_NO_1P5)):
        if np.any(mask):
            scale = np.polyval(fit_pars[0:3][::-1], m10)
            offset = np.polyval(fit_pars[3:6][::-1], m10)

            p_fail[mask] = (offset + scale * warm_frac)[mask]

    p_fail = norm.cdf(p_fail)  # probit transform
    p_fail[mag < 8.5] = 0.015  # actual best fit is ~0.006, but put in some conservatism
    p_success = (1 - p_fail)

    return p_success[0] if is_scalar else p_success  # Return scalar if ndim=0


def broadcast_arrays(*args):
    is_scalar = all(np.array(arg).ndim == 0 for arg in args)
    args = np.atleast_1d(*args)
    outs = [is_scalar] + np.broadcast_arrays(*args)
    return outs
