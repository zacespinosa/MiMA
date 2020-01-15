#! /bin/bash
#
#SBATCH -n 4
#SBATCH -o compileme.out
#SBATCH -e compileme.err
#
#cd /scratch/myoder96/Downloads/MiMA-1.0.1/exp
cd /scratch/myoder96/MiMA
#
#cd exec.SE3Mazama
#make clean
#cd ..
#
rm compileme.out
rm compileme.err
#
./compilescript_SE3Mazama.csh


