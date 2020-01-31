#!/bin/csh
#Minimal runscript for atmospheric dynamical cores
#
# Starting from the Mazama template...
#
# Load available modules...
module purge

# SRCC Sherlock:
module load icc/2019
module load ifort/2019
module load impi/2019
#module load openmpi/3.1.2
#
# we compiled curl with netcdf, etc. but this module might work as well:
# module load system curl/7.54.0
#
# Eventually these parts should be handled in module scripts, but for now we'll do it here:
# base directories:
set NETCDF_DIR = $SCRATCH/.local/intel/19.1.0.166/netcdfc/4.7.3
set NETCDF_FORTRAN_DIR=$SCRATCH/.local/intel/19.1.0.166/netcdff/4.5.2
set HDF5_DIR=$SCRATCH/.local/intel/19.1.0.166/hdf5/1.10.6
set ZLIB_DIR=$SCRATCH/.local/intel/19.1.0.166/zlib/1.2.11
set CURL_DIR=$SCRATCH/.local/intel/19.1.0.166/curl/7.68.0
#
######################################################################
######################################################################
#
set MPI_DIR=$I_MPI_ROOT
#
# some convenience variables (can be defined at our discretion):
HDF5_INC=$HDF5_DIR/include
HDF5_LIB=$HDF5_DIR/lib
#
set PATH=$HDF5_DIR/bin:$CURL_DIR/bin:$ZLIB_DIR/bin:$NETCDF_DIR/bin:$NETCDF_FORTRAN_DIR/bin:$PATH
set INCLUDE=$HDF5_DIR/include:$CURL_DIR/include:$ZLIB_DIR/include:$NETCDF_DIR/include:$NETCDF_FORTRAN_DIR/include:$INCLUDE
set LD_LIBRARY_PATH=$HDF5_DIR/lib:$CURL_DIR/lib:$ZLIB_DIR/lib:$NETCDF_DIR/lib:$NETCDF_FORTRAN_DIR/lib:$INCLUDE
#
set MIMA_CONFIG_FFLAGS = "`nc-config --fflags; nf-config --fflags` -I${HDF5_INC} -I${HDF5_LIB} -I${MPI_DIR}/include  -I${MPI_DIR}/lib -I${NETCDF_FORTRAN_DIR}/lib"
#$ pnetcdf-config --cflags ompi; pnetcdf-config --cflags; pkg-config --cflags ompi-fort;
# not sure we have pkg-config for impi. let's just set the varaibles...
set MIMA_CONFIG_CFLAGS = "`nc-config --cflags; nf-config --cflags` -I${MPI_DIR}/include -I${HDF5_INC}"
# x; ncxx4-config --libs; pnetcdf-config --ldflags; pnetcdf-config --libs
#
# TODO: nc/f-config --libs, --flibs have lots of overlap. let's try to consolidate. Note also that HDF5 is probably included in the nc-config.
set MIMA_CONFIG_LDFLAGS = " -shared-intel -L/usr/local/lib `nc-config --libs; nc-config --flibs; nf-config --flibs` -L${MPI_DIR}/lib -L${HDF5_DIR}/lib"

# TODO: in the template, LDPATH should be getting set to MIMA_CONFIG_LDFLAGS, but it appears that it is not. It is, in fact, the very final compile step
#  that appears to be failing because the linking paths are not provided... and after all of this, it looks like it may just need the -L and -l prams for
#  NetCDF and NetCDF-fortran. so we can hack it manually if necessary, but it would be nice to make the script(s) work../.
#
#
set echo
#
echo "** cwd: " $cwd
echo "MIMA_CONFIG_FFLAGS: ${MIMA_CONFIG_FFLAGS}"
echo "MIMA_CONFIG_CFLAGS: ${MIMA_CONFIG_CFLAGS}"
echo "MIMA_CONFIG_LDFLAGS: ${MIMA_CONFIG_LDFLAGS}"
#
if (! $?MIMA_nPROCS) then
	set MIMA_nPROCS = 1
endif
echo "Compile on N=${MIMA_nPROCS} process"
#
#
#--------------------------------------------------------------------------------------------------------
# define variables
#set platform  = nyu                                     # A unique identifier for your platform
set platform  = Sherlock
set npes      = $MIMA_nPROCS                                       # number of processors
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
    icc -O -o $mppnccombine -I$NETCDF_DIR/include -I$NETCDF_FORTRAN_DIR/include  -L$NETCDF_DIR/lib -L$NETCDF_FORTRAN_DIR/lib -lnetcdf -lnetcdff $cwd/../postprocessing/mppnccombine.c
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
#

#$mkmf -p mima.x -t $template -c "$cppDefs" -a $sourcedir $pathnames /usr/local/include $NETCDF_INC $sourcedir/shared/mpp/include $sourcedir/shared/include
$mkmf -p mima.x -t $template -c "$cppDefs" -a $sourcedir $pathnames /usr/local/include ${NETCDF_DIR}/include ${NETCDF_FORTRAN_DIR}/include ${HDF5_DIR}/include ${MPI_DIR}/include $sourcedir/shared/mpp/include $sourcedir/shared/include
#
# yoder:
# this might work here -- setting LDFLAGS after all other things have passed, but it's breaking -- probably on some sort of c-shell + mkmf combined
#  syntax elsewhere. I think that the pkg-config, nc-config, nf-config, etc. calls produce some content that mkmf+cshell cannot handle, resulting in an
#  error like, "variable name must start with a letter" (so I think it's trying to define a variable in the middle of the variable definition string).
#set LDFLAGS = "${MIMA_CONFIG_LDFLAGS}"

make -f Makefile -j $npes
