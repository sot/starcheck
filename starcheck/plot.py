import os
import logging

import Quaternion
import numpy as np
import agasc
from Chandra.Time import DateTime
import matplotlib.pyplot as plt
from Ska.quatutil import radec2yagzag
import Ska.Numpy
from astropy.table import Table

TASK_NAME = 'starcheck_plotting'
logger = logging.getLogger(TASK_NAME)

# rc definitions
frontcolor = 'black'
backcolor = 'white'
plt.rcParams['lines.color'] = frontcolor
plt.rcParams['patch.edgecolor'] = frontcolor
plt.rcParams['text.color'] = frontcolor
plt.rcParams['axes.facecolor'] = backcolor
plt.rcParams['axes.edgecolor'] = frontcolor
plt.rcParams['axes.labelcolor'] = frontcolor
plt.rcParams['xtick.color'] = frontcolor
plt.rcParams['ytick.color'] = frontcolor
plt.rcParams['grid.color'] = frontcolor
plt.rcParams['figure.facecolor'] = backcolor
plt.rcParams['figure.edgecolor'] = backcolor
plt.rcParams['savefig.facecolor'] = backcolor
plt.rcParams['savefig.edgecolor'] = backcolor


def symsize(mag):
    # map mags to figsizes, defining
    # mag 6 as 20 and mag 11 as 1
    # interp should leave it at the bounding value outside
    # the range
    return np.interp(mag, [6.0, 11.0], [20.0, 1])


def star_plot(catalog=None, quat=None, field=None, title=None):
    fig = plt.figure(figsize=(4, 4))
    ax = fig.add_subplot(1, 1, 1)
    face = backcolor

    # plot the box and set the labels
    plt.xlim(2900, -2900)
    plt.ylim(-2900, 2900)
    b1hw = 2560
    box1 = plt.Rectangle((b1hw, -b1hw), -2 * b1hw, 2 * b1hw,
                         fill=False)
    ax.add_patch(box1)
    b2hw = 2600
    box2 = plt.Rectangle((b2hw, -b2hw), -2 * b2hw, 2 * b2hw,
                         fill=False)
    ax.add_patch(box2)

    ax.scatter([-2700, -2700, -2700, -2700, -2700],
               [2400, 2100, 1800, 1500, 1200],
               c='orange', edgecolors='orange',
               s=symsize(np.array([10.0, 9.0, 8.0, 7.0, 6.0])))

    [l.set_rotation(90) for l in ax.get_yticklabels()]
    ax.grid()
    ax.set_ylabel("Zag (arcsec)")
    ax.set_xlabel("Yag (arcsec)")

    # plot starcheck catalog
    if catalog is not None:
        cat = Table(catalog)
        gui = cat[cat['type'] == 'GUI']
        acq = cat[cat['type'] == 'ACQ']
        bot = cat[cat['type'] == 'BOT']
        fid = cat[cat['type'] == 'FID']
        for row in cat:
            ax.annotate("%s" % row['idx'],
                        xy=(row['yang'] - 120, row['zang'] + 60))
        ax.scatter(gui['yang'], gui['zang'],
                   facecolors=face,
                   edgecolors='green',
                   s=100)
        ax.scatter(bot['yang'], bot['zang'],
                   facecolors=face,
                   edgecolors='green',
                   s=100)
        for acq_star in acq:
            acq_box = plt.Rectangle(
                (acq_star['yang'] - acq_star['halfw'],
                 acq_star['zang'] - acq_star['halfw']),
                width=acq_star['halfw'] * 2,
                height=acq_star['halfw'] * 2,
                color='blue',
                fill=False)
            ax.add_patch(acq_box)
        for acq_star in bot:
            acq_box = plt.Rectangle(
                (acq_star['yang'] - acq_star['halfw'],
                 acq_star['zang'] - acq_star['halfw']),
                width=acq_star['halfw'] * 2,
                height=acq_star['halfw'] * 2,
                color='blue',
                fill=False)
            ax.add_patch(acq_box)
        ax.scatter(fid['yang'], fid['zang'],
                   facecolors=face,
                   edgecolors='green',
                   marker='o',
                   s=200)
        ax.scatter(fid['yang'], fid['zang'],
                   facecolors=face,
                   edgecolors='green',
                   marker='+',
                   linewidth=3,
                   s=200)

    # plot field if present
    if field is not None:
        faint_plot_mag = 11.0
        bright_field = field[field['MAG_ACA'] < faint_plot_mag]
        yags = []
        zags = []
        for star in bright_field:
            yag, zag = radec2yagzag(star['RA_PMCORR'],
                                    star['DEC_PMCORR'],
                                    quat)
            yag *= 3600
            zag *= 3600
            yags.append(yag)
            zags.append(zag)

        bright_field = Ska.Numpy.add_column(bright_field,
                                            'yang',
                                            yags)
        bright_field = Ska.Numpy.add_column(bright_field,
                                            'zang',
                                            zags)
        color = np.ones(len(bright_field), dtype='|S10')
        color[:] = 'red'
        faint = ((bright_field['CLASS'] == 0)
                 & (bright_field['MAG_ACA'] >= 10.7))
        color[faint] = 'orange'
        ok = ((bright_field['CLASS'] == 0)
              & (bright_field['MAG_ACA'] < 10.7))
        color[ok] = frontcolor
        size = symsize(bright_field['MAG_ACA'])
        ax.scatter(bright_field['yang'], bright_field['zang'],
                   c=color, s=size, edgecolors=color)
        if title is not None:
            fig.suptitle(title)
    return fig


def plots_for_obsid(obsid, ra, dec, roll, starcat_time, catalog, outdir):
    ra = float(ra)
    dec = float(dec)
    roll = float(roll)
    field = agasc.get_agasc_cone(ra, dec,
                                 radius=1.5,
                                 date=DateTime(starcat_time).date)
    cat_plot = catalog_plot(ra, dec, roll, starcat_time, catalog, field=field,
                            title="RA %.2f Dec %.2f" % (ra, dec))
    cat_plot.savefig(os.path.join(outdir, 'stars_{}.png'.format(obsid)))
    plt.close(cat_plot)
    f_plot = field_plot(ra, dec, roll, starcat_time, field=field, title='field')
    f_plot.savefig(os.path.join(outdir, 'star_view_{}.png'.format(obsid)))
    plt.close(f_plot)


def catalog_plot(ra, dec, roll, starcat_time, catalog, field=None, title=None):
    quat = Quaternion.Quat([ra, dec, roll])
    if field is None:
        field = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog, quat, field, title=title)
    return fig


def field_plot(ra, dec, roll, starcat_time, field=None, title=None):
    quat = Quaternion.Quat([ra, dec, roll])
    if field is None:
        field = agasc.get_agasc_cone(ra, dec,
                                     radius=1.5,
                                     date=DateTime(starcat_time).date)
    fig = star_plot(catalog=None, quat=quat, field=field, title=title)
    return fig
