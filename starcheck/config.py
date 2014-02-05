import chandra_models
import sys
config = {'verbose': 1,
          'traceback': True,
          'pitch': 150,
          'json_obsids': sys.stdin,
          'output_temps': sys.stdout,
          }

configvars = config.keys()
configvars.append('oflsdir')
