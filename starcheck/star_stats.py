from __future__ import print_function, division

from Chandra.Time import DateTime
from itertools import izip
import numpy as np

# Scale and offset fit of polynomial to acq failures in log space.
# Derived in the fit_sota_model_probit.ipynb IPython notebook for data
# covering 2007-Jan-01 - 2015-July-01.
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


def t_ccd_for_n_acq(date, mags):
    def n_acq(t_ccd):
        probs = get_acq_success(date, t_ccd, mags)
        return np.sum(probs)


def acq_success_prob(date=None, t_ccd=-19.0, mag=10.0, color=0.6, spoiler=False):
    """
    Return probability of acquisition success for given date, temperature and mag.

    Any of the inputs can be scalars or arrays, with the output being the result of
    the broadcasted dimension of the inputs.

    This is based on the dark model and acquisition success model presented
    in the State of the ACA 2013.

    :param date: Date(s) (scalar or np.ndarray)
    :param t_ccd: CD temperature(s) (degC, scalar or np.ndarray)
    :param mag: Star magnitude(s) (scalar or np.ndarray)
    :param color: Star color(s) (scalar or np.ndarray)
    :param spoil: Star spoiled (boolean or np.ndarray)

    :returns: Acquisition success probability(s)
    """
    from mica.archive.aca_dark.dark_model import get_warm_fracs

    date = DateTime(date).secs

    is_scalar, dates, t_ccds, mags, colors, spoilers = broadcast_arrays(date, t_ccd, mag,
                                                                        color, spoiler)

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
    since it does not account for star properties like spoiled, color etc, and can return
    probability values outside of 0 to 1.

    Uses the empirical relation::

       P_acq_fail = Normal_CDF(offset(mag) + scale(mag) * warm_frac)
       P_acq_success = 1 - P_acq_fail

    :param mag: ACA magnitude (float)
    :param warm_frac: N100 warm fraction (float)
    :param color: B-V color (used to check for B-V=1.5 => red star)
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
