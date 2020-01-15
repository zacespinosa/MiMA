#!/bin/csh
#Minimal runscript for atmospheric dynamical cores
#
# Mazama:
# from prefix: /opt/ohpc/pub/moduledeps/intel
#
# get proper compiler (intel), mpi environment:
module purge
module unuse /usr/local/modulefiles
#

#module load intel
#module load mvapich2
module load intel/19.1.0.166
#module load mvapich2/2.3.2
module load openmpi3

#
# from prefix: /opt/ohpc/pub/moduledeps/intel-openmpi3
module load netcdf/4.7.1
module load netcdf-fortran/4.5.2
module load netcdf-cxx/4.3.1
module load pnetcdf/1.12.0
#
#
echo "** cwd: " $cwd

#
set echo 
#--------------------------------------------------------------------------------------------------------
# define variables
#set platform  = nyu                                     # A unique identifier for your platform
set platform  = SE3Mazama
set npes      = 1                                       # number of processors
set template  = $cwd/../bin/mkmf.template.$platform   # path to template for your platform
set mkmf      = $cwd/../bin/mkmf                      # path to executable mkmf
set sourcedir = $cwd/../src                           # path to directory containing model source code
set mppnccombine = $cwd/../bin/mppnccombine.$platform # path to executable mppnccombine
#--------------------------------------------------------------------------------------------------------
set execdir   = $cwd/exec.$platform       # where code is compiled and executable is created
set workdir   = $cwd/workdir              # where model is run and model output is produced
set pathnames = $cwd/path_names           # path to file containing list of source paths
set namelist  = $cwd/namelists            # path to namelist file
set diagtable = $cwd/diag_table           # path to diagnositics table
set fieldtable = $cwd/field_table         # path to field table (specifies tracers)
#--------------------------------------------------------------------------------------------------------
#
echo **
echo "*** compile step..."
# compile mppnccombine.c, will be used only if $npes > 1
if ( ! -f $mppnccombine ) then
  #icc -O -o $mppnccombine -I$NETCDF_INC -L$NETCDF_LIB $cwd/../postprocessing/mppnccombine.c -lnetcdf
    icc -O -o $mppnccombine -I$NETCDF_INC -L$NETCDF_LIB $cwd/../postprocessing/mppnccombine.c -lnetcdf -lnetcdff
endif
#--------------------------------------------------------------------------------------------------------

echo **
echo "*** set up directory structure..."
# setup directory structure
if ( ! -d $execdir ) mkdir $execdir
if ( -e $workdir ) then
  echo "ERROR: Existing workdir may contaminate run.  Move or remove $workdir and try again."
  exit 1
endif
#--------------------------------------------------------------------------------------------------------
echo **
echo "*** compile the model code and create executable"
# compile the model code and create executable
cd $execdir
#set cppDefs = "-Duse_libMPI -Duse_netCDF"
set cppDefs = "-Duse_libMPI -Duse_netCDF -DgFortran"

#$mkmf -p mima.x -t $template -c "$cppDefs" -a $sourcedir $pathnames /usr/local/include $NETCDF_INC $sourcedir/shared/mpp/include $sourcedir/shared/include
$mkmf -p mima.x -t $template -c "$cppDefs" -a $sourcedir $pathnames /usr/local/include $NETCDF_INC $NETCDF_FORTRAN_INC $sourcedir/shared/mpp/include $sourcedir/shared/include
#
echo "*** *** DEBUG: * ## *, NETCDF_INC: * ${NETCDF_INC} *, NETCDF_FORTRAN_INC: * ${NETCDF_FORTRAN_INC} *" 
#
make -f Makefile -j $npes
