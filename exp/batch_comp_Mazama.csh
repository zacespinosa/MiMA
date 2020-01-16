#! /bin/bash
#
#SBATCH -n 4
#SBATCH -o /scratch/myoder96/MiMA/exp/compileme.out
#SBATCH -e /scratch/myoder96/MiMA/exp/compileme.err
#
#DO_CLEAN=1
#
export MIMA_nPROCS=4
#cd /scratch/myoder96/Downloads/MiMA-1.0.1/exp
cd /scratch/myoder96/MiMA/exp
#
#if [$DO_CLEAN == 1]; then
cd exec.SE3Mazama
make clean
cd ..
#fi
#
#rm /scratch/myoder96/MiMA/exp/compileme.out
#rm /scratch/myoder96/MiMA/exp/compileme.err
#
echo "curr dir:  `pwd`"
./compilescript_SE3Mazama.csh

