import chandra_models
import sys
config = {'verbose': 1,
          'traceback': True,
          'model_spec': chandra_models.get_xija_model_file('aca'),
          'pitch': 150,
          'outdir': 'testa',
          'json_obsids': sys.stdin,
          'output_temps': sys.stdout,
          'oflsdir':'/data/mpcrit1/mplogs/2014/JAN1114/oflsa',
          }

configvars = config.keys()
#configvars.append('oflsdir')
