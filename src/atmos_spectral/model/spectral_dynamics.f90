module spectral_dynamics_mod

use                fms_mod, only: mpp_pe, mpp_root_pe, error_mesg, NOTE, FATAL, write_version_number, stdlog, &
                                  close_file, open_namelist_file, open_restart_file, file_exist, set_domain,  &
                                  read_data, write_data, check_nml_error, lowercase, uppercase, mpp_npes,     &
                                  field_size

use          constants_mod, only: rdgas, rvgas, grav, cp_air, omega, radius, pi

use       time_manager_mod, only: time_type, get_time, set_time, get_calendar_type, NO_CALENDAR, &
                                  get_date, interval_alarm, operator( - ), operator( + )

use      field_manager_mod, only: MODEL_ATMOS, parse

use     tracer_manager_mod, only: get_number_tracers, query_method, get_tracer_index, get_tracer_names, NO_TRACER, &
                                  tracer_requires_init, query_tracer_init

use       diag_manager_mod, only: diag_axis_init, register_diag_field, register_static_field, send_data

use         transforms_mod, only: transforms_init,         transforms_end,            &
                                  get_grid_boundaries,     area_weighted_global_mean, &
                                  compute_gradient_cos,    trans_spherical_to_grid,   &
                                  trans_grid_to_spherical, divide_by_cos,             &
                                  triangular_truncation,   rhomboidal_truncation,     &
                                  compute_laplacian,       get_eigen_laplacian,       &
                                  get_spherical_wave,      get_sin_lat,               &
                                  vor_div_from_uv_grid,    uv_grid_from_vor_div,      &
                                  horizontal_advection,    get_grid_domain,           &
                                  get_spec_domain,         grid_domain,               &
                                  spectral_domain,         get_deg_lon, get_deg_lat

use     vert_advection_mod, only: vert_advection, SECOND_CENTERED, FOURTH_CENTERED, VAN_LEER_LINEAR, FINITE_VOLUME_PARABOLIC, &
                                  ADVECTIVE_FORM

use           implicit_mod, only: implicit_init, implicit_end, implicit_correction

use   press_and_geopot_mod, only: press_and_geopot_init, press_and_geopot_end, &
                                  pressure_variables, compute_geopotential, compute_pressures_and_heights

use   spectral_damping_mod, only: spectral_damping_init, spectral_damping_end, compute_spectral_damping, &
                                  compute_spectral_damping_vor, compute_spectral_damping_div

use           leapfrog_mod, only: leapfrog, leapfrog_2level_A, leapfrog_2level_B

use       fv_advection_mod, only: fv_advection_init, fv_advection_end, a_grid_horiz_advection

use    water_borrowing_mod, only: water_borrowing

use    global_integral_mod, only: mass_weighted_global_integral

use spectral_init_cond_mod, only: spectral_init_cond

use        tracer_type_mod, only: tracer_type, tracer_type_version, tracer_type_tagname

use every_step_diagnostics_mod, only: every_step_diagnostics_init, every_step_diagnostics, every_step_diagnostics_end
!===============================================================================================
implicit none
private
!===============================================================================================

public :: spectral_dynamics_init, spectral_dynamics, spectral_dynamics_end, get_num_levels
public :: get_use_virtual_temperature, get_reference_sea_level_press, get_surf_geopotential
public :: get_pk_bk, complete_robert_filter, complete_update_of_future
public :: get_axis_id, spectral_diagnostics, get_initial_fields

!===============================================================================================

character(len=128), parameter :: version = '$Id: spectral_dynamics.f90,v 11.0.4.2 2005/06/09 18:54:54 pjp Exp $'
character(len=128), parameter :: tagname = '$Name:  $'

!===============================================================================================
! variables needed for diagnostics
integer :: id_ps, id_u, id_v, id_t, id_vor, id_div, id_omega, id_wspd, id_slp, id_div9
integer :: id_pres_full, id_pres_half, id_zfull, id_zhalf
integer :: id_uu, id_vv, id_tt, id_omega_omega, id_uv, id_omega_t
integer, allocatable, dimension(:) :: id_tr
real :: gamma, expf, expf_inverse
character(len=8) :: mod_name = 'dynamics'
integer, dimension(4) :: axis_id
!===============================================================================================

integer, parameter :: num_time_levels = 2

logical :: module_is_initialized = .false.
logical :: dry_model
logical :: robert_complete_for_tracers=.true., robert_complete_for_fields=.true. ! Needed only for error checks during code development

type(time_type) :: Time_step, Alarm_time, Alarm_interval ! Used to determine when it is time to print global integrals.

real,    allocatable, dimension(:) :: sin_lat, coriolis
real,    allocatable, dimension(:) :: pk, bk, dpk, dbk

complex, allocatable, dimension(:,:,:,:)   :: vors, divs, ts ! last dimension is for time level
complex, allocatable, dimension(:,:,:  )   :: ln_ps          ! last dimension is for time level
complex, allocatable, dimension(:,:,:,:,:) :: spec_tracers   ! 4'th dimension is for time level, last dimension is for tracer number

real, allocatable, dimension(:,:,:    ) :: psg               ! last dimension is for time level
real, allocatable, dimension(:,:,:,:  ) :: ug, vg, tg        ! last dimension is for time level
real, allocatable, dimension(:,:,:,:,:) :: grid_tracers      ! 4'th dimension is for time level, last dimension is for tracer number
real, allocatable, dimension(:,:      ) :: surf_geopotential
real, allocatable, dimension(:,:,:    ) :: vorg, divg        ! no time levels needed

integer, allocatable, dimension(:) :: tracer_vert_advect_scheme

real    :: virtual_factor, dt_real
integer :: pe, npes, num_tracers, nhum, t_vert_advect_scheme, uv_vert_advect_scheme, step_number
real    :: mean_energy_previous, mean_water_previous, mean_surf_press_previous
integer :: ms, me, ns, ne, is, ie, js, je
integer :: previous, current, future

character(len=32), parameter :: default_representation = 'spectral'
character(len=32), parameter :: default_advect_vert    = 'second_centered'
character(len=32), parameter :: default_hole_filling   = 'off'


! epg+ray: this netcdf include file is needed to load in specified initial
! conditions.  Only used if specify_initial_conditions == .true.
include 'netcdf.inc'

!===============================================================================================
! namelist variables

logical :: do_mass_correction     = .true. , &
           do_water_correction    = .true. , &
           do_energy_correction   = .true. , &
           use_virtual_temperature= .false., &
           use_implicit           = .true.,  &
           triang_trunc           = .true.

integer :: damping_order       = 2, &
           damping_order_vor   =-1, &
           damping_order_div   =-1, &
           lon_max             = 128, & ! T42
           lat_max             = 64,  & ! T42
           num_fourier         = 42,  & ! T42
           num_spherical       = 43,  & ! T42
           fourier_inc         = 1,   &
           num_levels          = 18,  &
           num_steps           = 1

integer, dimension(2) ::  print_interval=(/1,0/)

character(len=64) :: topography_option      = 'interpolated', & ! realistic topography computed from high resolution raw data
                     vert_coord_option      = 'even_sigma',   &
                     damping_option         = 'resolution_dependent', &
                     vert_advect_uv         = default_advect_vert,   &
                     vert_advect_t          = default_advect_vert,   &
                     vert_difference_option = 'simmons_and_burridge'

real    :: damping_coeff       = 1.15740741e-4, & ! (one tenth day)**-1
           damping_coeff_vor   = -1., &
           damping_coeff_div   = -1., &
           eddy_sponge_coeff   =  0., &
           zmu_sponge_coeff    =  0., &
           zmv_sponge_coeff    =  0., &
           robert_coeff        = .03, &
           alpha_implicit      = .5,  &
           longitude_origin    =  0., &
           scale_heights       =  4., &
           surf_res            = .1,  &
           p_press             = .1,  &
           p_sigma             = .3,  &
           exponent            = 2.5, &
         ocean_topog_smoothing = .93, &
           initial_sphum       = 0.0, &
     reference_sea_level_press =  101325. , &
           water_correction_limit = 0.e2 !mj

!epg+ray: this next namelist variable allows you to upload initial conditions
!         u,v,T, ps, and q must be specified (as: ucomp, vcomp, temp, ps, and sphum, respecitively)
!         in a netcdf file called "initial_conditions.nc" and placed in the INPUT/ directory
logical :: specify_initial_conditions = .false.



!===============================================================================================

real, dimension(2) :: valid_range_t = (/ 100.,500./)

namelist /spectral_dynamics_nml/ use_virtual_temperature, damping_option,                            &
                                 damping_order, damping_coeff, damping_order_vor, damping_coeff_vor, &
                                 damping_order_div, damping_coeff_div, do_mass_correction,           &
                                 do_water_correction, do_energy_correction, vert_advect_uv,          &
                                 vert_advect_t, use_implicit, longitude_origin, robert_coeff,        &
                                 alpha_implicit, vert_difference_option,                             &
                                 reference_sea_level_press, lon_max, lat_max, num_levels,            &
                                 num_fourier, num_spherical, fourier_inc, triang_trunc,              &
                                 topography_option, vert_coord_option, scale_heights, surf_res,      &
                                 p_press, p_sigma, exponent, ocean_topog_smoothing, initial_sphum,   &
                                 valid_range_t, eddy_sponge_coeff, zmu_sponge_coeff, zmv_sponge_coeff, &
                                 print_interval, num_steps,                                          &
                                 water_correction_limit                                                 !mj

contains

!===============================================================================================

subroutine spectral_dynamics_init(Time, Time_step_in, tracer_attributes, dry_model_out, nhum_out, ocean_mask)

type(time_type), intent(in) :: Time, Time_step_in
type(tracer_type), intent(inout), dimension(:) :: tracer_attributes
logical, intent(out) :: dry_model_out
integer, intent(out) :: nhum_out
logical, optional, intent(in), dimension(:,:) :: ocean_mask

integer :: num_total_wavenumbers, unit, k, seconds, days, ierr, io, ntr, nsphum, nmix_rat
logical :: south_to_north = .true.
real    :: ref_surf_p_implicit, robert_coeff_tracers

real,    allocatable, dimension(:,:) :: eigen
integer, allocatable, dimension(:,:) :: wavenumber
real,    allocatable, dimension(:)   :: glon_bnd, glat_bnd, ref_temperature_implicit
character(len=32) :: chtmp, scheme, params
character(len=128) :: tname, longname, units, tracer_restart_file

! < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < >

if(module_is_initialized) return

unit = open_namelist_file()
ierr=1
do while (ierr /= 0)
  read(unit, nml=spectral_dynamics_nml, iostat=io, end=20)
  ierr = check_nml_error (io, 'spectral_dynamics_nml')
enddo
20 call close_file (unit)

call write_version_number(version, tagname)
if(mpp_pe() == mpp_root_pe()) write (stdlog(), nml=spectral_dynamics_nml)
call write_version_number(tracer_type_version, tracer_type_tagname)

Time_step  = Time_step_in
Alarm_interval = set_time(print_interval(2), print_interval(1))
Alarm_time = Time + Alarm_interval

if(damping_order_vor == -1 ) damping_order_vor = damping_order
if(damping_order_div == -1 ) damping_order_div = damping_order
if(damping_coeff_vor == -1.) damping_coeff_vor = damping_coeff
if(damping_coeff_div == -1.) damping_coeff_div = damping_coeff

call check_dynamics_nml

if(uppercase(trim(vert_advect_uv)) == 'SECOND_CENTERED') then
  uv_vert_advect_scheme = SECOND_CENTERED
else if(uppercase(trim(vert_advect_uv)) == 'FOURTH_CENTERED') then
  uv_vert_advect_scheme = FOURTH_CENTERED
else if(uppercase(trim(vert_advect_uv)) == 'VAN_LEER_LINEAR') then
  uv_vert_advect_scheme = VAN_LEER_LINEAR
else if(uppercase(trim(vert_advect_uv)) == 'FINITE_VOLUME_PARABOLIC') then
  uv_vert_advect_scheme = FINITE_VOLUME_PARABOLIC
else
  call error_mesg('spectral_dynamics_init','"'//trim(vert_advect_uv)//'"'//' is not a valid value for vert_advect_uv.', FATAL)
endif

if(uppercase(trim(vert_advect_t)) == 'SECOND_CENTERED') then
  t_vert_advect_scheme = SECOND_CENTERED
else if(uppercase(trim(vert_advect_t)) == 'FOURTH_CENTERED') then
  t_vert_advect_scheme = FOURTH_CENTERED
else if(uppercase(trim(vert_advect_t)) == 'VAN_LEER_LINEAR') then
  t_vert_advect_scheme = VAN_LEER_LINEAR
else if(uppercase(trim(vert_advect_t)) == 'FINITE_VOLUME_PARABOLIC') then
  t_vert_advect_scheme = FINITE_VOLUME_PARABOLIC
else
  call error_mesg('spectral_dynamics_init','"'//trim(vert_advect_t)//'"'//' is not a valid value for vert_advect_t.', FATAL)
endif

! transforms_init must be called before the remaining
! restart data can be read or the fields can be allocated.
! This is because transforms_init calls spec_mpp_init,
! which is where domains are determined.

call transforms_init(radius, lat_max, lon_max, num_fourier, fourier_inc, num_spherical, south_to_north=south_to_north, &
                     triang_trunc=triang_trunc, longitude_origin=longitude_origin)

call get_grid_domain(is, ie, js, je)
call get_spec_domain(ms, me, ns, ne)
call get_number_tracers(MODEL_ATMOS, num_prog=num_tracers)
call allocate_fields

do ntr=1,num_tracers

  call get_tracer_names(MODEL_ATMOS, ntr, tname, longname, units)
  tracer_attributes(ntr)%name = lowercase(tname)

  if(query_method('numerical_representation', MODEL_ATMOS, ntr, scheme)) then
    tracer_attributes(ntr)%numerical_representation = scheme
  else
    tracer_attributes(ntr)%numerical_representation = default_representation
  endif

  if(query_method('advect_vert', MODEL_ATMOS, ntr, scheme)) then
    tracer_attributes(ntr)%advect_vert = scheme
  else
    tracer_attributes(ntr)%advect_vert = default_advect_vert
  endif

  if(query_method('hole_filling', MODEL_ATMOS, ntr, scheme)) then
    tracer_attributes(ntr)%hole_filling = scheme
  else
    tracer_attributes(ntr)%hole_filling = default_hole_filling
  endif

  if(query_method('robert_filter', MODEL_ATMOS, ntr, scheme, params)) then
    if(uppercase(scheme) == 'OFF') then
      tracer_attributes(ntr)%robert_coeff = 0.0
    else
      if(parse(params,'robert_coeff', robert_coeff_tracers) == 1) then
        tracer_attributes(ntr)%robert_coeff = robert_coeff_tracers
      else
        tracer_attributes(ntr)%robert_coeff = robert_coeff
      endif
    endif
  else
    tracer_attributes(ntr)%robert_coeff = robert_coeff
  endif
  if(mpp_pe() == mpp_root_pe()) then
     write (stdlog(),'(/,80("="))')
     write (stdlog(), "(a,3x,a,3x,a,3x,a)") &
            'tracer='//trim(tracer_attributes(ntr)%name), &
            'numerical_representation='//trim(tracer_attributes(ntr)%numerical_representation), &
            'advect_vert='//trim(tracer_attributes(ntr)%advect_vert), &
            'hole_filling='//trim(tracer_attributes(ntr)%hole_filling)
  endif

  if(trim(tracer_attributes(ntr)%numerical_representation) == 'spectral') then
    tracer_attributes(ntr)%advect_horiz = 'spectral'
  else if(trim(tracer_attributes(ntr)%numerical_representation) == 'grid') then
    tracer_attributes(ntr)%advect_horiz = 'van_leer'
  else
    call error_mesg('spectral_dynamics_init',trim(tracer_attributes(ntr)%numerical_representation)// &
           ' is an invalid numerical_representation', FATAL)
  endif

  if(trim(tracer_attributes(ntr)%numerical_representation) == 'grid') then
    if(trim(tracer_attributes(ntr)%hole_filling) == 'on') then
      call error_mesg('spectral_dynamics_init','Warning: hole_filling scheme = on will be ignored for grid tracer '// &
      tracer_attributes(ntr)%name,NOTE)
    endif
  endif

enddo

nsphum   = get_tracer_index(MODEL_ATMOS, 'sphum')
nmix_rat = get_tracer_index(MODEL_ATMOS, 'mix_rat')

if(nsphum == NO_TRACER) then
  if(nmix_rat == NO_TRACER) then
    nhum = 0
    dry_model = .true.
  else
    nhum = nmix_rat
    dry_model = .false.
  endif
else
  if(nmix_rat == NO_TRACER) then
    nhum = nsphum
    dry_model = .false.
  else
    call error_mesg('spectral_dynamics_init','sphum and mix_rat cannot both be specified as tracers at the same time', FATAL)
  endif
endif
dry_model_out = dry_model
nhum_out = nhum

allocate(tracer_vert_advect_scheme(num_tracers))

do ntr=1,num_tracers
  if(uppercase(trim(tracer_attributes(ntr)%advect_vert)) == 'SECOND_CENTERED') then
    tracer_vert_advect_scheme(ntr) = SECOND_CENTERED
  else if(uppercase(trim(tracer_attributes(ntr)%advect_vert)) == 'FOURTH_CENTERED') then
    tracer_vert_advect_scheme(ntr) = FOURTH_CENTERED
  else if(uppercase(trim(tracer_attributes(ntr)%advect_vert)) == 'VAN_LEER_LINEAR') then
    tracer_vert_advect_scheme(ntr) = VAN_LEER_LINEAR
  else if(uppercase(trim(tracer_attributes(ntr)%advect_vert)) == 'FINITE_VOLUME_PARABOLIC') then
    tracer_vert_advect_scheme(ntr) = FINITE_VOLUME_PARABOLIC
  else
    call error_mesg('spectral_dynamics_init',trim(tracer_attributes(ntr)%advect_vert)// &
         ' is not a valid vertical advection scheme for tracers. Check your field_table.', FATAL)
  endif
enddo

call read_restart_or_do_coldstart(tracer_attributes, ocean_mask)

call press_and_geopot_init(pk, bk, use_virtual_temperature, vert_difference_option, surf_geopotential)

call spectral_diagnostics_init(Time)

call every_step_diagnostics_init(Time, lon_max, lat_max, num_levels, reference_sea_level_press)

if(do_water_correction .and. .not.do_mass_correction) then
  call error_mesg('spectral_dynamics_init', 'water_correction requires mass_correction', FATAL)
endif

if(do_energy_correction .and. .not.do_mass_correction) then
  call error_mesg('spectral_dynamics_init', 'energy_correction requires mass_correction', FATAL)
endif

pe   = mpp_pe()
npes = mpp_npes()

if(triang_trunc) then
  num_total_wavenumbers = num_spherical - 1
else
  num_total_wavenumbers = num_spherical - 1 + fourier_inc*num_fourier
end if

if(use_virtual_temperature) then
  virtual_factor = (rvgas/rdgas) - 1.0
end if

allocate (sin_lat (js:je))
allocate (coriolis(js:je))

call get_sin_lat (sin_lat)

coriolis = 2*omega*sin_lat

allocate (glon_bnd (lon_max + 1))
allocate (glat_bnd (lat_max + 1))

call get_grid_boundaries(glon_bnd, glat_bnd, global=.true.)
call fv_advection_init  (lon_max, lat_max, glat_bnd, 360./fourier_inc)

deallocate (glat_bnd)
deallocate (glon_bnd)

allocate(dpk(size(pk,1)-1))
allocate(dbk(size(bk,1)-1))

do k=1,size(pk,1)-1
  dpk(k) = pk(k+1) - pk(k)
  dbk(k) = bk(k+1) - bk(k)
enddo

call spectral_damping_init(damping_coeff, damping_order, damping_option, num_fourier, num_spherical, &
                           num_levels, eddy_sponge_coeff, zmu_sponge_coeff, zmv_sponge_coeff,        &
                           damping_coeff_vor=damping_coeff_vor, damping_order_vor=damping_order_vor, &
                           damping_coeff_div=damping_coeff_div, damping_order_div=damping_order_div)

if(use_implicit) then
  allocate(wavenumber(0:num_fourier,0:num_spherical))
  allocate(     eigen(0:num_fourier,0:num_spherical))
  allocate (ref_temperature_implicit(num_levels))
  ref_temperature_implicit(:) = 300.
  ref_surf_p_implicit = reference_sea_level_press

  call get_spherical_wave(wavenumber)
  call get_eigen_laplacian(eigen)

  call implicit_init(pk, bk, ref_temperature_implicit, ref_surf_p_implicit, num_total_wavenumbers, &
                     eigen, wavenumber, alpha_implicit, vert_difference_option)

  deallocate(eigen, wavenumber, ref_temperature_implicit)
endif

call set_domain(grid_domain)

call get_time(Time_step, seconds, days)
dt_real = 86400*days + seconds

module_is_initialized = .true.
return
end subroutine spectral_dynamics_init

!===============================================================================================
subroutine read_restart_or_do_coldstart(tracer_attributes, ocean_mask)

! For backward compatability, this routine has the capability
! to read native data restart files written by inchon code.

type(tracer_type), intent(inout), dimension(:) :: tracer_attributes
logical, optional, intent(in), dimension(:,:) :: ocean_mask

integer :: m, n, k, nt, ntr, unit
integer, dimension(4) :: siz
real, dimension(ms:me, ns:ne, num_levels) :: real_part, imag_part
character(len=64) :: file, tr_name
character(len=4) :: ch1,ch2,ch3,ch4,ch5,ch6

! epg+ray: for loading the initial tracer distribution (after Lorenzo Polvani's code for doing this)
real, allocatable,dimension(:,:,:) :: lmptmp
integer :: ncid,vid,err,counts(3)
! ------

file = 'INPUT/spectral_dynamics.res.nc'
if(file_exist(trim(file))) then
  call field_size(trim(file), 'vors_real', siz)
  if(num_fourier /= siz(1)-1 .or. num_spherical /= siz(2)-1 .or. num_levels /= siz(3)) then
    write(ch1,'(i4)') siz(1)-1
    write(ch2,'(i4)') siz(2)-1
    write(ch3,'(i4)') siz(3)
    write(ch4,'(i4)') num_fourier
    write(ch5,'(i4)') num_spherical
    write(ch6,'(i4)') num_levels
    call error_mesg('spectral_dynamics_init','Resolution of restart data does not match resolution specified on namelist.'// &
    ' Restart data: num_fourier='//ch1//', num_spherical='//ch2//', num_levels='//ch3// &
       '  Namelist: num_fourier='//ch4//', num_spherical='//ch5//', num_levels='//ch6, FATAL)
  endif
  call field_size(trim(file), 'ug', siz)
  if(lon_max /= siz(1) .or. lat_max /= siz(2)) then
    write(ch1,'(i4)') siz(1)
    write(ch2,'(i4)') siz(2)
    write(ch3,'(i4)') lon_max
    write(ch4,'(i4)') lat_max
    call error_mesg('spectral_dynamics_init','Resolution of restart data does not match resolution specified on namelist.'// &
    ' Restart data: lon_max='//ch1//', lat_max='//ch2//'  Namelist: lon_max='//ch3//', lat_max='//ch4, FATAL)
  endif
  call read_data(trim(file), 'previous', previous, no_domain=.true.)
  call read_data(trim(file), 'current',  current,  no_domain=.true.)
  call read_data(trim(file), 'pk', pk, no_domain=.true.)
  call read_data(trim(file), 'bk', bk, no_domain=.true.)
  do nt=1,num_time_levels
    call read_data(trim(file), 'vors_real',  real_part, spectral_domain, timelevel=nt)
    call read_data(trim(file), 'vors_imag',  imag_part, spectral_domain, timelevel=nt)
    do k=1,num_levels; do n=ns,ne; do m=ms,me
      vors(m,n,k,nt) = cmplx(real_part(m,n,k),imag_part(m,n,k))
    enddo; enddo; enddo
    call read_data(trim(file), 'divs_real',  real_part, spectral_domain, timelevel=nt)
    call read_data(trim(file), 'divs_imag',  imag_part, spectral_domain, timelevel=nt)
    do k=1,num_levels; do n=ns,ne; do m=ms,me
      divs(m,n,k,nt) = cmplx(real_part(m,n,k),imag_part(m,n,k))
    enddo; enddo; enddo
    call read_data(trim(file), 'ts_real',  real_part, spectral_domain, timelevel=nt)
    call read_data(trim(file), 'ts_imag',  imag_part, spectral_domain, timelevel=nt)
    do k=1,num_levels; do n=ns,ne; do m=ms,me
      ts(m,n,k,nt) = cmplx(real_part(m,n,k),imag_part(m,n,k))
    enddo; enddo; enddo
    call read_data(trim(file), 'ln_ps_real', real_part(:,:,1), spectral_domain, timelevel=nt)
    call read_data(trim(file), 'ln_ps_imag', imag_part(:,:,1), spectral_domain, timelevel=nt)
    do n=ns,ne; do m=ms,me
      ln_ps(m,n,nt) = cmplx(real_part(m,n,1),imag_part(m,n,1))
    enddo; enddo
    call read_data(trim(file), 'ug',   ug(:,:,:,nt), grid_domain, timelevel=nt)
    call read_data(trim(file), 'vg',   vg(:,:,:,nt), grid_domain, timelevel=nt)
    call read_data(trim(file), 'tg',   tg(:,:,:,nt), grid_domain, timelevel=nt)
    call read_data(trim(file), 'psg', psg(:,:,  nt), grid_domain, timelevel=nt)
    do ntr = 1,num_tracers
      tr_name = trim(tracer_attributes(ntr)%name)
      call read_data(trim(file), trim(tr_name), grid_tracers(:,:,:,nt,ntr), grid_domain, timelevel=nt)
      if(uppercase(trim(tracer_attributes(ntr)%numerical_representation)) == 'SPECTRAL') then
        call read_data(trim(file), trim(tr_name)//'_real', real_part, spectral_domain, timelevel=nt)
        call read_data(trim(file), trim(tr_name)//'_imag', imag_part, spectral_domain, timelevel=nt)
        do k=1,num_levels; do n=ns,ne; do m=ms,me
          spec_tracers(m,n,k,nt,ntr) = cmplx(real_part(m,n,k),imag_part(m,n,k))
        enddo; enddo; enddo
      endif
    enddo ! loop over tracers
  enddo ! loop over time levels
  call read_data(trim(file), 'vorg', vorg, grid_domain)
  call read_data(trim(file), 'divg', divg, grid_domain)
  call read_data(trim(file), 'surf_geopotential', surf_geopotential, grid_domain)
else if(file_exist('INPUT/spectral_dynamics.res')) then
  call error_mesg('spectral_dynamics_init', &
              'Binary restart file, INPUT/spectral_dynamics.res, is not supported by this version of spectral_dynamics.f90',FATAL)
else
  previous = 1
  current  = 1
  call spectral_init_cond(reference_sea_level_press, triang_trunc, use_virtual_temperature, topography_option,  &
                          vert_coord_option, vert_difference_option, scale_heights, surf_res, p_press, p_sigma, &
                          exponent, ocean_topog_smoothing, pk, bk,                                              &
                          vors(:,:,:,1), divs(:,:,:,1), ts(:,:,:,1), ln_ps(:,:,1), ug(:,:,:,1), vg(:,:,:,1),    &
                          tg(:,:,:,1), psg(:,:,1), vorg, divg, surf_geopotential, ocean_mask,specify_initial_conditions)

  vors (:,:,:,2) = vors (:,:,:,1)
  divs (:,:,:,2) = divs (:,:,:,1)
  ts   (:,:,:,2) = ts   (:,:,:,1)
  ln_ps(:,:,  2) = ln_ps(:,:,  1)
  ug   (:,:,:,2) = ug   (:,:,:,1)
  vg   (:,:,:,2) = vg   (:,:,:,1)
  tg   (:,:,:,2) = tg   (:,:,:,1)
  psg  (:,:,  2) = psg  (:,:,  1)
  do ntr = 1,num_tracers
    if(trim(tracer_attributes(ntr)%name) == 'sphum') then
      if(specify_initial_conditions) then  
         !epg+ray: This loads in sphum from the file initial_conditions.nc
         if (.not.file_exist('initial_conditions.nc')) then
            call error_mesg('spectral_initialize_fields','Could not find initial_conditions.nc!',FATAL)
         endif
         
         ! open up the netcdf file`
         ncid = ncopn('initial_conditions.nc',NCNOWRIT,err)
         ! This array tells us the size of input variables.
         counts(1) = size(grid_tracers,1)
         counts(2) = size(grid_tracers,2)
         counts(3) = size(grid_tracers,3)
         ! Allocate space to put the initial condition information, temporarily.
         allocate(lmptmp(counts(1),counts(2),counts(3)))          
         
         ! load sphum, if it has been specified.  Otherwise write error and break.
         vid = ncvid(ncid,'sphum',err)
         if(err == 0) then
            call ncvgt(ncid,vid,(/is,js,1/),counts,lmptmp,err)
            grid_tracers(:,:,:,1,ntr) = lmptmp
            grid_tracers(:,:,:,2,ntr) = lmptmp
            if(mpp_pe() == mpp_root_pe()) then
               print *,'tracer ', trim(tracer_attributes(ntr)%name), ' read in from initial_conditions.nc'
            endif
         else
            call error_mesg('read_restart_or_do_coldstart','Could not find '//trim(tracer_attributes(ntr)%name)// &
                'in initial_conditions.nc',FATAL)
         endif
      else 
         grid_tracers(:,:,:,:,ntr) = initial_sphum
      endif
    else if(trim(tracer_attributes(ntr)%name) == 'mix_rat') then
      grid_tracers(:,:,:,:,ntr) = 0.
    else
      grid_tracers(:,:,:,:,ntr) = 0.
    endif
    call trans_grid_to_spherical(grid_tracers(:,:,:,1,ntr), spec_tracers(:,:,:,1,ntr))
    spec_tracers(:,:,:,2,ntr) = spec_tracers(:,:,:,1,ntr)
  enddo
endif

return
end subroutine read_restart_or_do_coldstart
!===============================================================================================

subroutine allocate_fields
integer :: ntr

allocate (psg    (is:ie, js:je,             num_time_levels))
allocate (ug     (is:ie, js:je, num_levels, num_time_levels))
allocate (vg     (is:ie, js:je, num_levels, num_time_levels))
allocate (tg     (is:ie, js:je, num_levels, num_time_levels))

allocate (ln_ps(ms:me, ns:ne,             num_time_levels))
allocate ( vors(ms:me, ns:ne, num_levels, num_time_levels))
allocate ( divs(ms:me, ns:ne, num_levels, num_time_levels))
allocate (   ts(ms:me, ns:ne, num_levels, num_time_levels))

allocate (pk(num_levels+1), bk(num_levels+1))

allocate (vorg(is:ie, js:je, num_levels))
allocate (divg(is:ie, js:je, num_levels))

allocate (surf_geopotential(is:ie, js:je))

allocate (grid_tracers(is:ie, js:je, num_levels, num_time_levels, num_tracers))
allocate (spec_tracers(ms:me, ns:ne, num_levels, num_time_levels, num_tracers))

! Filling allocatable arrays with zeros immediately after allocation facilitates code debugging
psg=0.; ug=0.; vg=0.; tg=0.
ln_ps=cmplx(0.,0.); vors=cmplx(0.,0.); divs=cmplx(0.,0.); ts=cmplx(0.,0.); spec_tracers=cmplx(0.,0.)
pk=0.; bk=0.; vorg=0.; divg=0.; surf_geopotential=0.; grid_tracers=0.

return
end subroutine allocate_fields
!===============================================================================================
subroutine check_dynamics_nml

character(len=8)  :: ch_tmp1
character(len=16) :: ch_tmp2
integer :: itmp

!  Check for invalid values and incompatible combinations of namelist variables

if(num_fourier <= 0) then
  write(ch_tmp1,'(i8)') num_fourier
  call error_mesg('check_dynamics_nml',ch_tmp1//'is an invalid value for num_fourier.', FATAL)
endif

if(num_spherical <= 0) then
  write(ch_tmp1,'(i8)') num_spherical
  call error_mesg('check_dynamics_nml',ch_tmp1//'is an invalid value for num_spherical.', FATAL)
endif

if(fourier_inc <= 0) then
  write(ch_tmp1,'(i8)') fourier_inc
  call error_mesg('check_dynamics_nml',ch_tmp1//'is an invalid value for fourier_inc.', FATAL)
endif

if(num_levels <= 0) then
  write(ch_tmp1,'(i8)') num_levels
  call error_mesg('check_dynamics_nml',ch_tmp1//'is an invalid value for num_levels.', FATAL)
endif

if(lon_max < 3*num_fourier+1) then
  write(ch_tmp1,'(i8)') lon_max
  write(ch_tmp2,'(i8)') num_fourier
  call error_mesg('check_dynamics_nml','number of longitude points is too small for number of fourier waves.&
                  & lon_max='//ch_tmp1//'  num_fourier='//ch_tmp2, FATAL)
endif

if (triang_trunc) then
  itmp = 3
else
  itmp = 5
endif
if(2*lat_max < itmp*(num_spherical-1)+1) then
  write(ch_tmp1,'(i8)') lat_max
  write(ch_tmp2,'(i8)') num_spherical
  call error_mesg('check_dynamics_nml','number of latitude points is too small for number of meridional waves.&
                  &  lat_max='//ch_tmp1//'  num_spherical='//ch_tmp2, FATAL)
endif

if(damping_order < 0) then
  write(ch_tmp1,'(i8)') damping_order
  call error_mesg('check_dynamics_nml',ch_tmp1//' is an invalid value for damping_order.', FATAL)
endif

if(damping_order_vor < 0) then
  write(ch_tmp1,'(i8)') damping_order_vor
  call error_mesg('check_dynamics_nml',ch_tmp1//' is an invalid value for damping_order_vor.', FATAL)
endif

if(damping_order_div < 0) then
  write(ch_tmp1,'(i8)') damping_order_div
  call error_mesg('check_dynamics_nml',ch_tmp1//' is an invalid value for damping_order_div.', FATAL)
endif

if(damping_coeff < 0.) then
  write(ch_tmp2,'(e16.8)') damping_coeff
  call error_mesg('check_dynamics_nml',ch_tmp2//' is an invalid value for damping_coeff.', FATAL)
endif

if(damping_coeff_vor < 0.) then
  write(ch_tmp2,'(e16.8)') damping_coeff_vor
  call error_mesg('check_dynamics_nml',ch_tmp2//' is an invalid value for damping_coeff_vor.', FATAL)
endif

if(damping_coeff_div < 0.) then
  write(ch_tmp2,'(e16.8)') damping_coeff_div
  call error_mesg('check_dynamics_nml',ch_tmp2//' is an invalid value for damping_coeff_div.', FATAL)
endif

if(robert_coeff < 0. .or. robert_coeff > 1.) then
  write(ch_tmp2,'(1pe16.8)') robert_coeff
  call error_mesg('check_dynamics_nml',ch_tmp2//' is an invalid value for robert_coeff.', FATAL)
endif

if((do_energy_correction .or. do_water_correction) .and. .not.do_mass_correction) then
  call error_mesg('check_dynamics_nml','.not.do_mass_correction must be .true. when either &
           &do_energy_correction or do_water_correction is .true.', FATAL)
endif

return

end subroutine check_dynamics_nml
!===============================================================================================
subroutine get_initial_fields(ug_out, vg_out, tg_out, psg_out, grid_tracers_out)
real, intent(out), dimension(:,:,:)   :: ug_out, vg_out, tg_out
real, intent(out), dimension(:,:)     :: psg_out
real, intent(out), dimension(:,:,:,:) :: grid_tracers_out

if(.not.module_is_initialized) then
  call error_mesg('get_initial_fields','dynamics has not been initialized',FATAL)
endif

if(previous /= 1 .or. current /= 1) then
  call error_mesg('get_initial_fields','This routine may be called only to get the&
                  & initial values after a cold_start',FATAL)
endif

ug_out  =  ug(:,:,:,1)
vg_out  =  vg(:,:,:,1)
tg_out  =  tg(:,:,:,1)
psg_out = psg(:,:,  1)
grid_tracers_out = grid_tracers(:,:,:,1,:)

end subroutine get_initial_fields
!===============================================================================================

subroutine spectral_dynamics(Time, psg_final, ug_final, vg_final, tg_final, tracer_attributes, grid_tracers_final, &
                             dt_psg, dt_ug, dt_vg, dt_tg, dt_tracers, wg_full, p_full, p_half, z_full)

type(time_type),  intent(in) :: Time
real, intent(out), dimension(is:ie, js:je) :: psg_final
real, intent(out), dimension(is:ie, js:je, num_levels) :: ug_final, vg_final, tg_final
real, intent(out), dimension(is:ie, js:je, num_levels, num_tracers) :: grid_tracers_final
type(tracer_type),intent(inout), dimension(:) :: tracer_attributes

real, intent(inout), dimension(is:ie, js:je                             ) :: dt_psg
real, intent(inout), dimension(is:ie, js:je, num_levels                 ) :: dt_ug, dt_vg, dt_tg
real, intent(inout), dimension(is:ie, js:je, num_levels, num_tracers    ) :: dt_tracers
real, intent(out),   dimension(is:ie, js:je, num_levels                 ) :: wg_full, p_full
real, intent(out),   dimension(is:ie, js:je, num_levels+1               ) :: p_half
real, intent(in),    dimension(is:ie, js:je, num_levels                 ) :: z_full

! < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < >

type(time_type) :: Time_diag

complex, dimension(ms:me, ns:ne              ) :: dt_ln_ps
complex, dimension(ms:me, ns:ne, num_levels  ) :: dt_vors, dt_divs, dt_ts, phis_plus_ke
complex, dimension(ms:me, ns:ne, num_levels  ) :: dt_vors_damp, dt_divs_damp, dt_ts_damp
real   , dimension(is:ie, js:je, num_levels  ) :: virtual_t, dp, dt_grid_tmp
real   , dimension(is:ie, js:je, num_levels  ) :: kegen, kegenq, kegenqtinv, water_correction
real   , dimension(is:ie, js:je              ) :: dx_psg, dy_psg, ln_psg, dt_ln_psg
real   , dimension(is:ie, js:je, num_levels  ) :: phig_full, ln_p_full, phig_full_plus_ke
real   , dimension(is:ie, js:je, num_levels+1) :: phig_half, ln_p_half, wg

real, dimension(is:ie, js:je                         ) :: dt_psg_tmp
real, dimension(is:ie, js:je, num_levels             ) :: dt_ug_tmp, dt_vg_tmp, dt_tg_tmp
real, dimension(is:ie, js:je, num_levels             ) :: dt_ug_damp, dt_vg_damp, dt_tg_damp
real, dimension(is:ie, js:je, num_levels, num_tracers) :: dt_tracers_tmp

integer :: j, k, time_level, seconds, days, nsphum
real    :: delta_t, temperature_correction
real, dimension(num_tracers) :: dt_hadv, dt_vadv
!mj error message
real    :: extrtmp
integer :: ii,jj,kk,i1,j1,k1

! < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < > < >

if(.not.module_is_initialized) then
  call error_mesg('spectral_dynamics','dynamics has not been initialized ', FATAL)
endif

step_loop: do step_number=1,num_steps

if(previous == current) then
  delta_t = dt_real/num_steps
else
  delta_t = 2*dt_real/num_steps
endif
if(num_time_levels == 2) then
  future = 3 - current
else
  call error_mesg('spectral_dynamics','Do not know how to set time pointers when num_time_levels does not equal 2',FATAL)
endif

dt_psg_tmp = dt_psg
dt_ug_tmp  = dt_ug
dt_vg_tmp  = dt_vg
dt_tg_tmp  = dt_tg
dt_tracers_tmp = dt_tracers

call initialize_corrections(dt_ug, dt_vg, dt_tg, dt_tracers, delta_t)

call pressure_variables (p_half, ln_p_half, p_full, ln_p_full, psg(:,:,current))

call compute_pressure_gradient  (ln_ps(:,:,current), psg(:,:,current), dx_psg, dy_psg)

if (use_virtual_temperature .and. .not.dry_model) then
  virtual_t = tg(:,:,:,current)*(1.0 + virtual_factor*grid_tracers(:,:,:,current,nhum))
else
  virtual_t = tg(:,:,:,current)
endif

call four_in_one (divg, ug(:,:,:,current), vg(:,:,:,current), virtual_t, grid_tracers(:,:,:,current,nhum), psg(:,:,current), &
   ln_p_half, ln_p_full, p_full, dx_psg, dy_psg, dt_psg_tmp, wg, wg_full, dt_tg_tmp, dt_ug_tmp, dt_vg_tmp, &
   kegen, kegenq, kegenqtinv)

if(dry_model) then
  call compute_geopotential(tg(:,:,:,current), ln_p_half, ln_p_full, phig_full, phig_half)
else
  call compute_geopotential(tg(:,:,:,current), ln_p_half, ln_p_full, phig_full, phig_half, grid_tracers(:,:,:,current,nhum))
endif

dt_ln_psg = dt_psg_tmp/psg(:,:,current)
call trans_grid_to_spherical(dt_ln_psg, dt_ln_ps)

dp = p_half(:,:,2:num_levels+1) - p_half(:,:,1:num_levels)

if(uv_vert_advect_scheme == SECOND_CENTERED .or.  uv_vert_advect_scheme == FOURTH_CENTERED)         time_level=current
if(uv_vert_advect_scheme == VAN_LEER_LINEAR .or.  uv_vert_advect_scheme == FINITE_VOLUME_PARABOLIC) time_level=previous
call vert_advection(delta_t, wg, dp, ug(:,:,:,time_level), dt_grid_tmp, scheme=uv_vert_advect_scheme, form=ADVECTIVE_FORM)
dt_ug_tmp = dt_ug_tmp + dt_grid_tmp
call vert_advection(delta_t, wg, dp, vg(:,:,:,time_level), dt_grid_tmp, scheme=uv_vert_advect_scheme, form=ADVECTIVE_FORM)
dt_vg_tmp = dt_vg_tmp + dt_grid_tmp

if(t_vert_advect_scheme == SECOND_CENTERED .or.  t_vert_advect_scheme == FOURTH_CENTERED)         time_level=current
if(t_vert_advect_scheme == VAN_LEER_LINEAR .or.  t_vert_advect_scheme == FINITE_VOLUME_PARABOLIC) time_level=previous
call vert_advection(delta_t, wg, dp, tg(:,:,:,time_level),  dt_grid_tmp, scheme=t_vert_advect_scheme, form=ADVECTIVE_FORM)
dt_tg_tmp = dt_tg_tmp + dt_grid_tmp

call horizontal_advection(ts(:,:,:,current), ug(:,:,:,current), vg(:,:,:,current), dt_tg_tmp)
call trans_grid_to_spherical(dt_tg_tmp, dt_ts)

do k=1,num_levels
  do j = js,je
    dt_ug_tmp(:,j,k) = dt_ug_tmp(:,j,k) + (vorg(:,j,k) + coriolis(j))*vg(:,j,k,current)
    dt_vg_tmp(:,j,k) = dt_vg_tmp(:,j,k) - (vorg(:,j,k) + coriolis(j))*ug(:,j,k,current)
  enddo
enddo

call vor_div_from_uv_grid(dt_ug_tmp, dt_vg_tmp, dt_vors, dt_divs, triang = triang_trunc)

phig_full_plus_ke = phig_full + .5*(ug(:,:,:,current)**2 + vg(:,:,:,current)**2)
call trans_grid_to_spherical(phig_full_plus_ke, phis_plus_ke)
dt_divs = dt_divs - compute_laplacian(phis_plus_ke)

if(use_implicit) call implicit_correction (dt_divs, dt_ts, dt_ln_ps, divs, ts, ln_ps, delta_t, previous, current)

call compute_spectral_damping_vor (vors(:,:,:,previous), dt_vors, delta_t, dt_vors_damp)
call compute_spectral_damping_div (divs(:,:,:,previous), dt_divs, delta_t, dt_divs_damp)
call compute_spectral_damping     (ts  (:,:,:,previous), dt_ts,   delta_t, dt_ts_damp)

call uv_grid_from_vor_div    (dt_vors_damp, dt_divs_damp, dt_ug_damp, dt_vg_damp)
call trans_spherical_to_grid (dt_ts_damp, dt_tg_damp)

if(.not.robert_complete_for_fields) then
  call error_mesg('spectral_dynamics','robert_complete_for_fields should be .true.',FATAL)
endif
if(.not.robert_complete_for_tracers) then
  call error_mesg('spectral_dynamics','robert_complete_for_tracers should be .true.',FATAL)
endif

if(step_number == num_steps) then
  call leapfrog_2level_A(ln_ps, dt_ln_ps, previous, current, future, delta_t, robert_coeff)
  call leapfrog_2level_A(vors,  dt_vors,  previous, current, future, delta_t, robert_coeff)
  call leapfrog_2level_A(divs,  dt_divs,  previous, current, future, delta_t, robert_coeff)
  call leapfrog_2level_A(ts,    dt_ts,    previous, current, future, delta_t, robert_coeff)
  robert_complete_for_fields = .false.
else
  call leapfrog         (ln_ps, dt_ln_ps, previous, current, future, delta_t, robert_coeff)
  call leapfrog         (vors , dt_vors , previous, current, future, delta_t, robert_coeff)
  call leapfrog         (divs , dt_divs , previous, current, future, delta_t, robert_coeff)
  call leapfrog         (ts   , dt_ts   , previous, current, future, delta_t, robert_coeff)
  robert_complete_for_fields = .true.
endif

call trans_spherical_to_grid(divs(:,:,:,future), divg)
call trans_spherical_to_grid(vors(:,:,:,future), vorg)
call uv_grid_from_vor_div(vors(:,:,:,future), divs(:,:,:,future), ug(:,:,:,future), vg(:,:,:,future))
call trans_spherical_to_grid(ts   (:,:,:,future), tg(:,:,:,future))
call trans_spherical_to_grid(ln_ps(:,:,  future), ln_psg)
psg(:,:,future) = exp(ln_psg)

if(minval(tg(:,:,:,future)) < valid_range_t(1) .or. maxval(tg(:,:,:,future)) > valid_range_t(2)) then
!mj
   if(minval(tg(:,:,:,future)) < valid_range_t(1))then
      extrtmp = minval(tg(:,:,:,future))
   else
      extrtmp = maxval(tg(:,:,:,future))
   endif
   do k1=1,size(tg,3)
      do j1=1,size(tg,2)
         do i1=1,size(tg,1)
            if(tg(i1,j1,k1,future) .eq. extrtmp)then
               ii=i1
               jj=j1
               kk=k1
               exit
            endif
         enddo
      enddo
   enddo
   write(*,'(a,i3,a,3i3,2f10.3)')'PE, location, Textr(curr,future): ',mpp_pe()&
        &,': ',ii,jj,kk&
        &,tg(ii,jj,kk,current)&
        &,tg(ii,jj,kk,future)
   write(*,'(a,i3,a,3i3,2f10.3)')'PE, location, Uextr(curr,future): ',mpp_pe()&
        &,': ',ii,jj,kk&
        &,ug(ii,jj,kk,current)&
        &,ug(ii,jj,kk,future)
!jm
  call error_mesg('spectral_dynamics','temperatures out of valid range', FATAL)
endif

call update_tracers(tracer_attributes, dt_tracers_tmp, wg, p_half, delta_t, dt_hadv, dt_vadv)
!mj add a vertical limit to water correction
!call compute_corrections(delta_t, tracer_attributes, temperature_correction, water_correction)
call compute_corrections(delta_t, tracer_attributes, temperature_correction, water_correction, p_full)

previous = current
current  = future

call get_time(Time, seconds, days)
seconds = seconds + step_number*int(dt_real/2)
Time_diag = set_time(seconds, days)
call every_step_diagnostics( &
     Time_diag, psg(:,:,current), ug(:,:,:,current), vg(:,:,:,current), tg(:,:,:,current), grid_tracers(:,:,:,current,:), &
     wg_full, p_full, p_half, z_full, dt_ug_damp, dt_vg_damp, dt_tg_damp, temperature_correction, water_correction, &
     dt_hadv, dt_vadv, kegen, kegenq, kegenqtinv)

enddo step_loop

psg_final = psg(:,:,  current)
ug_final  =  ug(:,:,:,current)
vg_final  =  vg(:,:,:,current)
tg_final  =  tg(:,:,:,current)
grid_tracers_final = grid_tracers(:,:,:,current,:)

return
end subroutine spectral_dynamics

!================================================================================

subroutine four_in_one(divg, u_grid, v_grid, t_grid, q_grid, p_surf, ln_p_half, ln_p_full, p_full, &
                       dx_psg, dy_psg, dt_psg, wg, wg_full, dt_tg, dt_ug, dt_vg, &
                       kegen, kegenq, kegenqtinv)

real, intent(in),    dimension(:,:,:) :: divg, u_grid, v_grid, t_grid, q_grid, ln_p_full, p_full
real, intent(in),    dimension(:,:  ) :: p_surf, dx_psg, dy_psg
real, intent(inout), dimension(:,:  ) :: dt_psg
real, intent(out),   dimension(:,:,:) :: wg_full, kegen, kegenq, kegenqtinv
real, intent(out),   dimension(:,:,:) :: wg
real, intent(in),    dimension(:,:,:) :: ln_p_half
real, intent(inout), dimension(:,:,:) :: dt_tg, dt_ug, dt_vg

!  wg is dimensioned (is:ie, js:je, num_levels+1)
!  wg(:,:,k) = grav*(downward mass flux per unit area) across the K+1/2
!  cell boundary. This is the "vertical velocity" in the hybrid coordinate system.
!  When vertical coordinate is pure sigma: wg = psg*d(sigma)/dt
!  wg_full is the vertical velocity at full levels.

real, dimension(is:ie, js:je) :: dp, dp_inv, dlog_1, dlog_2, dlog_3, dmean, dmean_tot
real, dimension(is:ie, js:je) :: x1, x2, x3, x4, x5, p_surf_inv

real :: kappa
integer :: k

kappa = rdgas/cp_air

dmean_tot = 0.

if(vert_difference_option == 'simmons_and_burridge') then
  do k = 1,num_levels
    dp = dpk(k) + dbk(k)*p_surf
    dp_inv = 1/dp
    dlog_1 = ln_p_half(:,:,k+1) - ln_p_full(:,:,k)
    dlog_2 = ln_p_full(:,:,k)   - ln_p_half(:,:,k)
    dlog_3 = ln_p_half(:,:,k+1) - ln_p_half(:,:,k)
    x1 = (bk(k+1)*dlog_1 + bk(k)*dlog_2)*dp_inv
    x2 = x1*dx_psg
    x3 = x1*dy_psg
    dt_ug(:,:,k) = dt_ug(:,:,k) - rdgas*t_grid(:,:,k)*x2
    dt_vg(:,:,k) = dt_vg(:,:,k) - rdgas*t_grid(:,:,k)*x3
    dmean = divg(:,:,k)*dp + dbk(k)*(u_grid(:,:,k)*dx_psg + v_grid(:,:,k)*dy_psg)
    x4 = (dmean_tot*dlog_3 + dmean*dlog_1)*dp_inv
    x5 = x4 - u_grid(:,:,k)*x2 - v_grid(:,:,k)*x3
    dt_tg(:,:,k) = dt_tg(:,:,k) - kappa*t_grid(:,:,k) * x5
    kegen(:,:,k) = -kappa*t_grid(:,:,k) * x5
    kegenq(:,:,k) = -kappa*t_grid(:,:,k) * x5 * q_grid(:,:,k)
    kegenqtinv(:,:,k) = -kappa * x5 * q_grid(:,:,k)
    wg_full(:,:,k) = -x5*p_full(:,:,k)
    dmean_tot = dmean_tot + dmean
    wg(:,:,k+1) = - dmean_tot
  enddo
else if(vert_difference_option == 'mcm') then
  p_surf_inv = 1.0/p_surf
  do k = 1,num_levels
    dp = dpk(k) + dbk(k)*p_surf
    x2 = dx_psg*p_surf_inv
    x3 = dy_psg*p_surf_inv
    dt_ug(:,:,k) = dt_ug(:,:,k) - rdgas*t_grid(:,:,k)*x2
    dt_vg(:,:,k) = dt_vg(:,:,k) - rdgas*t_grid(:,:,k)*x3
    dmean = divg(:,:,k)*dp + dbk(k)*(u_grid(:,:,k)*dx_psg + v_grid(:,:,k)*dy_psg)
    x4 = (dmean_tot + 0.5*dmean)/p_full(:,:,k)
    x5 = x4 - u_grid(:,:,k)*x2 - v_grid(:,:,k)*x3
    dt_tg(:,:,k) = dt_tg(:,:,k) - kappa*t_grid(:,:,k) * x5
    wg_full(:,:,k) = -x5*p_full(:,:,k)
    dmean_tot = dmean_tot + dmean
    wg(:,:,k+1) = - dmean_tot
  enddo
  kegen      = 0.0
  kegenq     = 0.0
  kegenqtinv = 0.0
endif

dt_psg = dt_psg - dmean_tot

do k = 2,num_levels
  wg(:,:,k) = wg(:,:,k) + dmean_tot*bk(k)
enddo

wg(:,:,1           ) = 0.0
wg(:,:,num_levels+1) = 0.0

return
end subroutine four_in_one

!================================================================================

subroutine update_tracers(tracer_attributes, dt_tr, wg, p_half, delta_t, dt_hadv, dt_vadv)

type(tracer_type), intent(inout), dimension(:) :: tracer_attributes
real   , intent(inout), dimension(:,:,:,:) :: dt_tr
real   , intent(in   ), dimension(:,:,:  ) :: wg, p_half
real   , intent(in   )  :: delta_t
real   , intent(out  ), dimension(:) :: dt_hadv, dt_vadv

complex, dimension(ms:me, ns:ne, num_levels) :: dt_trs
real,    dimension(is:ie, js:je, num_levels) :: dp, dt_tmp, tr_future
integer :: ntr, time_level

dp = p_half(:,:,2:num_levels+1) - p_half(:,:,1:num_levels)

do ntr = 1, num_tracers
  if(trim(tracer_attributes(ntr)%numerical_representation) == 'spectral') then
    dt_tmp = 0.0
    call horizontal_advection(spec_tracers(:,:,:,current,ntr), ug(:,:,:,current), vg(:,:,:,current), dt_tmp)
    dt_tr(:,:,:,ntr) = dt_tr(:,:,:,ntr) + dt_tmp
    dt_hadv(ntr) = mass_weighted_global_integral(dt_tmp, psg(:,:,future)) ! tendency of integrated tracer due to hor adv
    if(tracer_vert_advect_scheme(ntr) == SECOND_CENTERED .or. &
       tracer_vert_advect_scheme(ntr) == FOURTH_CENTERED)         time_level=current
    if(tracer_vert_advect_scheme(ntr) == VAN_LEER_LINEAR .or. &
       tracer_vert_advect_scheme(ntr) == FINITE_VOLUME_PARABOLIC) time_level=previous
    call vert_advection(delta_t, wg, dp, grid_tracers(:,:,:,time_level,ntr), dt_tmp, &
                     scheme=tracer_vert_advect_scheme(ntr), form=ADVECTIVE_FORM)
    dt_tr(:,:,:,ntr) = dt_tr(:,:,:,ntr) + dt_tmp
    dt_vadv(ntr) = mass_weighted_global_integral(dt_tmp, psg(:,:,future)) ! tendency of integrated tracer due to vert adv
    if(trim(tracer_attributes(ntr)%hole_filling) == 'on') then
      call water_borrowing (dt_tr(:,:,:,ntr), grid_tracers(:,:,:,previous,ntr), current, p_half, delta_t)
    endif
    call trans_grid_to_spherical  (dt_tr(:,:,:,ntr), dt_trs)
    call compute_spectral_damping (spec_tracers(:,:,:,previous,ntr), dt_trs, delta_t)
    if(step_number == num_steps) then
      call leapfrog_2level_A(spec_tracers(:,:,:,:,ntr),dt_trs,previous,current,future,delta_t,tracer_attributes(ntr)%robert_coeff)
      robert_complete_for_tracers = .false.
    else
      call leapfrog(spec_tracers(:,:,:,:,ntr),dt_trs,previous,current,future,delta_t,tracer_attributes(ntr)%robert_coeff)
      robert_complete_for_tracers = .true.
    endif
    call trans_spherical_to_grid  (spec_tracers(:,:,:,future,ntr), grid_tracers(:,:,:,future,ntr))
  else if(trim(tracer_attributes(ntr)%numerical_representation) == 'grid') then
    tr_future = grid_tracers(:,:,:,previous,ntr) + delta_t*dt_tr(:,:,:,ntr)
    dt_tr(:,:,:,ntr) = 0.0
    call a_grid_horiz_advection (ug(:,:,:,current), vg(:,:,:,current), tr_future, delta_t, dt_tr(:,:,:,ntr))
    tr_future = tr_future + delta_t*dt_tr(:,:,:,ntr)
    dt_hadv(ntr) = mass_weighted_global_integral(dt_tr(:,:,:,ntr), psg(:,:,future)) ! tendency of integrated tracer due to hor adv
    dp = p_half(:,:,2:num_levels+1) - p_half(:,:,1:num_levels)
    call vert_advection(delta_t, wg, dp, tr_future, dt_tmp, scheme=tracer_vert_advect_scheme(ntr), form=ADVECTIVE_FORM)
    tr_future = tr_future + delta_t*dt_tmp
    dt_vadv(ntr) = mass_weighted_global_integral(dt_tmp, psg(:,:,future)) ! tendency of integrated tracer due to vert adv
    if(step_number == num_steps) then
      grid_tracers(:,:,:,current,ntr) = grid_tracers(:,:,:,current,ntr) + &
      tracer_attributes(ntr)%robert_coeff*(grid_tracers(:,:,:,previous,ntr) - 2.0*grid_tracers(:,:,:,current,ntr))
      robert_complete_for_tracers = .false.
    else
      grid_tracers(:,:,:,current,ntr) = grid_tracers(:,:,:,current,ntr) + &
      tracer_attributes(ntr)%robert_coeff*(grid_tracers(:,:,:,previous,ntr) - 2.0*grid_tracers(:,:,:,current,ntr) + tr_future)
      robert_complete_for_tracers = .true.
    endif
    grid_tracers(:,:,:,future,ntr) = tr_future
  else
    call error_mesg('update_tracers',trim(tracer_attributes(ntr)%numerical_representation)// &
           ' is an invalid numerical_representation', FATAL)
  endif
enddo

return
end subroutine update_tracers

!=================================================================================================

subroutine compute_pressure_gradient(ln_ps, psg, dx_psg, dy_psg)

complex, intent(in ), dimension(:,:) :: ln_ps
real   , intent(in ), dimension(:,:) :: psg
real   , intent(out), dimension(:,:) :: dx_psg, dy_psg

complex, dimension(ms:me, ns:ne) :: dx_ln_ps, dy_ln_ps

call compute_gradient_cos(ln_ps, dx_ln_ps, dy_ln_ps)
call trans_spherical_to_grid(dx_ln_ps, dx_psg)
call trans_spherical_to_grid(dy_ln_ps, dy_psg)
dx_psg = psg*dx_psg
dy_psg = psg*dy_psg
call divide_by_cos(dx_psg)
call divide_by_cos(dy_psg)

return
end subroutine compute_pressure_gradient

!===================================================================================
!mj add a vertical limit to water correction
!subroutine compute_corrections(delta_t, tracer_attributes, temperature_correction, water_correction)
subroutine compute_corrections(delta_t, tracer_attributes, temperature_correction, water_correction, p_full)

real,              intent(in   )                   :: delta_t
type(tracer_type), intent(inout), dimension(:)     :: tracer_attributes
real,              intent(out  )                   :: temperature_correction
real,              intent(out  ), dimension(:,:,:) :: water_correction
real,              intent(in   ), dimension(:,:,:) :: p_full !mj

real :: mass_correction_factor, water_correction_factor
real :: mean_surf_press_tmp,    mean_energy_tmp,        mean_water_tmp
!mj selective water correction
real :: corr_water_tmp, not_corr_water_tmp
integer,dimension(size(water_correction,1),size(water_correction,2),size(water_correction,3)) :: water_mask

if(do_mass_correction) then
  mean_surf_press_tmp = area_weighted_global_mean(psg(:,:,future))
  mass_correction_factor = mean_surf_press_previous/mean_surf_press_tmp
  psg(:,:,future) = mass_correction_factor*psg(:,:,future)
  if(ms == 0 .and. ns == 0) then
    ln_ps(0,0,future) = ln_ps(0,0,future) + sqrt(2.)*log(mass_correction_factor)
  endif
endif

if(do_energy_correction) then
  mean_energy_tmp = mass_weighted_global_integral( &
          0.5*(ug(:,:,:,future)**2 + vg(:,:,:,future)**2) + cp_air*tg(:,:,:,future), psg(:,:,future))
  temperature_correction = grav*(mean_energy_previous - mean_energy_tmp)/(cp_air*mean_surf_press_previous)
  tg(:,:,:,future) = tg(:,:,:,future) + temperature_correction
  if(ms == 0 .and. ns == 0) then
    ts(0,0,:,future) = ts(0,0,:,future) + sqrt(2.)*temperature_correction
  endif
endif

if(do_water_correction) then
  if(dry_model) then
    call error_mesg('compute_corrections','do_water_correction must be .false. in a dry model (default is .true.)', FATAL)
  else
    mean_water_tmp  = mass_weighted_global_integral(grid_tracers(:,:,:,future,nhum), psg(:,:,future))
!mj add water correction upper limit
    water_mask = 0
    where ( p_full >= water_correction_limit )
       water_mask = 1
    endwhere
    corr_water_tmp    = mass_weighted_global_integral(grid_tracers(:,:,:,future,nhum)*water_mask, psg(:,:,future))
    water_mask = 0
    where ( p_full < water_correction_limit )
       water_mask = 1
    endwhere
    not_corr_water_tmp= mass_weighted_global_integral(grid_tracers(:,:,:,future,nhum)*water_mask, psg(:,:,future))
!
    if(mean_water_tmp > 0.) then
      water_correction_factor = mean_water_previous/mean_water_tmp
!mj add water correction upper limit
      water_correction_factor = water_correction_factor*(1.+not_corr_water_tmp/corr_water_tmp) - not_corr_water_tmp/corr_water_tmp
      water_correction = 0.
      where ( p_full >= water_correction_limit )
         water_correction = (water_correction_factor-1.)*grid_tracers(:,:,:,future,nhum)/delta_t
         grid_tracers(:,:,:,future,nhum) = water_correction_factor*grid_tracers(:,:,:,future,nhum)
      endwhere
      if(tracer_attributes(nhum)%numerical_representation == 'spectral') then
         where ( p_full > water_correction_limit )
            spec_tracers(:,:,:,future,nhum) = water_correction_factor*spec_tracers(:,:,:,future,nhum)
         endwhere
      endif
!jm
    endif
  endif
endif

return
end subroutine compute_corrections

!===================================================================================

subroutine initialize_corrections(dt_ug, dt_vg, dt_tg, dt_tracers, delta_t)

real,    intent(in), dimension(:,:,:)   :: dt_ug, dt_vg, dt_tg
real,    intent(in), dimension(:,:,:,:) :: dt_tracers
real,    intent(in) :: delta_t

real, dimension(is:ie, js:je, num_levels) :: energy
integer :: n

if(do_mass_correction) then
  mean_surf_press_previous = area_weighted_global_mean(psg(:,:,previous))
endif

if(do_energy_correction) then
   energy  =  0.5*((ug(:,:,:,previous)+dt_ug*delta_t)**2 + (vg(:,:,:,previous)+dt_vg*delta_t)**2)   &
               +cp_air*(tg(:,:,:,previous)+dt_tg*delta_t)
   mean_energy_previous = mass_weighted_global_integral( energy, psg(:,:,previous))

   energy  =  0.5*((ug(:,:,:,current)+dt_ug*delta_t)**2 + (vg(:,:,:,current)+dt_vg*delta_t)**2)   &
               +cp_air*(tg(:,:,:,current)+dt_tg*delta_t)
endif

if(do_water_correction) then
  if(dry_model) then
    call error_mesg('initialize_corrections','do_water_correction must be .false. in a dry model&
                     & (default is .true.)', FATAL)
  else
    mean_water_previous = &
      mass_weighted_global_integral(grid_tracers(:,:,:,previous,nhum) + delta_t*dt_tracers(:,:,:,nhum), psg(:,:,previous))
  endif
endif

return
end subroutine initialize_corrections

!================================================================================

subroutine get_surf_geopotential(surf_geopotential_out)
real, intent(out), dimension(:,:) :: surf_geopotential_out
character(len=64) :: chtmp='shape(surf_geopotential)=              should be                '

if(.not.module_is_initialized) then
  call error_mesg('get_surf_geopotential', 'spectral_dynamics_init has not been called.', FATAL)
endif

if(any(shape(surf_geopotential_out) /= shape(surf_geopotential))) then
  write(chtmp(26:37),'(3i4)') shape(surf_geopotential_out)
  write(chtmp(50:61),'(3i4)') shape(surf_geopotential)
  call error_mesg('get_surf_geopotential', 'surf_geopotential has wrong shape. '//chtmp, FATAL)
endif

surf_geopotential_out = surf_geopotential

return
end subroutine get_surf_geopotential
!================================================================================
subroutine get_reference_sea_level_press(reference_sea_level_press_out)
real, intent(out) :: reference_sea_level_press_out

if(.not.module_is_initialized) then
  call error_mesg('get_reference_sea_level_press', 'spectral_dynamics_init has not been called.', FATAL)
endif

reference_sea_level_press_out = reference_sea_level_press

return
end subroutine get_reference_sea_level_press
!================================================================================
subroutine get_use_virtual_temperature(use_virtual_temperature_out)
logical, intent(out) :: use_virtual_temperature_out

if(.not.module_is_initialized) then
  call error_mesg('get_use_virtual_temperature', 'spectral_dynamics_init has not been called.', FATAL)
endif

use_virtual_temperature_out = use_virtual_temperature

return
end subroutine get_use_virtual_temperature
!================================================================================
subroutine get_num_levels(num_levels_out)
integer, intent(out) :: num_levels_out

if(.not.module_is_initialized) then
  call error_mesg('get_num_levels', 'spectral_dynamics_init has not been called.', FATAL)
endif

num_levels_out = num_levels

return
end subroutine get_num_levels
!================================================================================
subroutine get_pk_bk(pk_out, bk_out)
real, intent(out), dimension(:) :: pk_out, bk_out
character(len=32) :: chtmp='size(pk)=      size(bk)=        '

if(.not.module_is_initialized) then
  call error_mesg('get_pk_bk', 'spectral_dynamics_init has not been called.', FATAL)
endif
if(size(pk_out,1) /= size(bk_out,1)) then
  write(chtmp(10:13),'(i4)') size(pk_out,1)
  write(chtmp(25:28),'(i4)') size(bk_out,1)
  call error_mesg('get_pk_bk', 'size(pk) is not equal to size(bk). '//chtmp, FATAL)
endif

pk_out = pk
bk_out = bk

return
end subroutine get_pk_bk
!================================================================================
subroutine complete_update_of_future(psg_in, ug_in, vg_in, tg_in, tracer_attributes, grid_tracers_in)

real,              intent(in), dimension(:,:    ) :: psg_in
real,              intent(in), dimension(:,:,:  ) :: ug_in, vg_in, tg_in
type(tracer_type), intent(in), dimension(:      ) :: tracer_attributes
real,              intent(in), dimension(:,:,:,:) :: grid_tracers_in
real, dimension(size(psg,1), size(psg,2)) :: ln_psg
integer :: ntr

! The time level pointers may be confusing here.
! The future level of the fields are passed to this routine in atmosphere_up,
! and they are loaded into the current level here.
! The reason for this is that the time level pointers in atmosphere_mod have
! not yet been updated, but they have been updated for spectral_dyanmics_mod
! (in Subroutine spectral_dynamics.) The result is that future in
! atmosphere_up points to the same time level as current in this routine.

!----------------------------------------------------------------------------

psg(:,:,  current) = psg_in
ug (:,:,:,current) = ug_in
vg (:,:,:,current) = vg_in
tg (:,:,:,current) = tg_in
grid_tracers(:,:,:,current,:) = grid_tracers_in

call vor_div_from_uv_grid(ug(:,:,:,current), vg(:,:,:,current), vors(:,:,:,current), divs(:,:,:,current), triang=triang_trunc)
call trans_spherical_to_grid(vors(:,:,:,current), vorg)
call trans_spherical_to_grid(divs(:,:,:,current), divg)
ln_psg = alog(psg(:,:,current))
call trans_grid_to_spherical(ln_psg, ln_ps(:,:,current))
call trans_grid_to_spherical(tg_in,  ts(:,:,:,current))
do ntr=1,num_tracers
  if(uppercase(trim(tracer_attributes(ntr)%numerical_representation)) == 'SPECTRAL') then
    call trans_grid_to_spherical(grid_tracers(:,:,:,current,ntr), spec_tracers(:,:,:,current,ntr))
  endif
enddo

return
end subroutine complete_update_of_future
!================================================================================
subroutine complete_robert_filter(tracer_attributes)
type(tracer_type), intent(inout), dimension(:) :: tracer_attributes
integer :: ntr

if(robert_complete_for_fields) then
  call error_mesg('complete_robert_filter','This routine should not be called when robert_complete_for_fields=.true.',FATAL)
endif
call leapfrog_2level_B(ln_ps, previous, current, robert_coeff)
call leapfrog_2level_B(vors,  previous, current, robert_coeff)
call leapfrog_2level_B(divs,  previous, current, robert_coeff)
call leapfrog_2level_B(ts,    previous, current, robert_coeff)
robert_complete_for_fields=.true.

if(num_tracers > 0 .and. robert_complete_for_tracers) then
  call error_mesg('complete_robert_filter','This routine should not be called when robert_complete_for_tracers=.true.',FATAL)
endif

do ntr = 1, num_tracers
  if(uppercase(trim(tracer_attributes(ntr)%numerical_representation)) == 'SPECTRAL') then
    call leapfrog_2level_B(spec_tracers(:,:,:,:,ntr), previous, current, tracer_attributes(ntr)%robert_coeff)
  else
    call leapfrog_2level_B(grid_tracers(:,:,:,:,ntr), previous, current, tracer_attributes(ntr)%robert_coeff)
  endif
  robert_complete_for_tracers=.true.
enddo

return
end subroutine complete_robert_filter
!================================================================================

subroutine spectral_dynamics_end(tracer_attributes, Time)

type(tracer_type), intent(in), dimension(:) :: tracer_attributes
type(time_type), intent(in), optional :: Time
integer :: ntr, nt
character(len=64) :: file, tr_name

if(.not.module_is_initialized) return

file='RESTART/spectral_dynamics.res'
call write_data(trim(file), 'previous', previous, no_domain=.true.)
call write_data(trim(file), 'current',  current,  no_domain=.true.)
call write_data(trim(file), 'pk', pk, no_domain=.true.)
call write_data(trim(file), 'bk', bk, no_domain=.true.)
do nt=1,num_time_levels
  call write_data(trim(file), 'vors_real',   real(vors (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'vors_imag',  aimag(vors (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'divs_real',   real(divs (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'divs_imag',  aimag(divs (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'ts_real',     real(ts   (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'ts_imag',    aimag(ts   (:,:,:,nt)), spectral_domain)
  call write_data(trim(file), 'ln_ps_real',  real(ln_ps(:,:,  nt)), spectral_domain)
  call write_data(trim(file), 'ln_ps_imag', aimag(ln_ps(:,:,  nt)), spectral_domain)
  call write_data(trim(file), 'ug',   ug(:,:,:,nt), grid_domain)
  call write_data(trim(file), 'vg',   vg(:,:,:,nt), grid_domain)
  call write_data(trim(file), 'tg',   tg(:,:,:,nt), grid_domain)
  call write_data(trim(file), 'psg', psg(:,:,  nt), grid_domain)
  do ntr = 1,num_tracers
    tr_name = trim(tracer_attributes(ntr)%name)
    call write_data(trim(file), trim(tr_name), grid_tracers(:,:,:,nt,ntr), grid_domain)
    if(uppercase(trim(tracer_attributes(ntr)%numerical_representation)) == 'SPECTRAL') then
      call write_data(trim(file), trim(tr_name)//'_real',  real(spec_tracers(:,:,:,nt,ntr)), spectral_domain)
      call write_data(trim(file), trim(tr_name)//'_imag', aimag(spec_tracers(:,:,:,nt,ntr)), spectral_domain)
    endif
  enddo
enddo
call write_data(trim(file), 'vorg', vorg, grid_domain)
call write_data(trim(file), 'divg', divg, grid_domain)
call write_data(trim(file), 'surf_geopotential', surf_geopotential, grid_domain)

deallocate(ug, vg, tg, psg)
deallocate(sin_lat, coriolis)
deallocate(pk, bk, dpk, dbk)
deallocate(ln_ps, vors, divs, ts)
deallocate(vorg, divg)
deallocate(surf_geopotential)
deallocate(spec_tracers, grid_tracers)

if(use_implicit) call implicit_end
call spectral_damping_end
call fv_advection_end
call every_step_diagnostics_end(Time)
call spectral_diagnostics_end
call press_and_geopot_end
call transforms_end
call set_domain(grid_domain)
module_is_initialized = .false.

return
end subroutine spectral_dynamics_end
!===================================================================================
subroutine spectral_diagnostics_init(Time)

type(time_type), intent(in) :: Time
real, dimension(lon_max  ) :: lon
real, dimension(lon_max+1) :: lonb
real, dimension(lat_max  ) :: lat
real, dimension(lat_max+1) :: latb
real, dimension(num_levels)   :: p_full, ln_p_full
real, dimension(num_levels+1) :: p_half, ln_p_half
integer, dimension(3) :: axes_3d_half, axes_3d_full
integer :: id_lonb, id_latb, id_phalf, id_lon, id_lat, id_pfull
integer :: id_pk, id_bk, id_zsurf, ntr, k
real :: rad_to_deg
logical :: used
real,dimension(2) :: vrange,trange
character(len=128) :: tname, longname, units

vrange = (/ -400., 400. /)
trange = (/  100., 400. /)

rad_to_deg = 180./pi
call get_grid_boundaries(lonb,latb,global=.true.)
call get_deg_lon(lon)
call get_deg_lat(lat)

id_lonb=diag_axis_init('lonb', rad_to_deg*lonb, 'degrees_E', 'x', 'longitude edges', set_name=mod_name, Domain2=grid_domain)
id_latb=diag_axis_init('latb', rad_to_deg*latb, 'degrees_N', 'y', 'latitude edges',  set_name=mod_name, Domain2=grid_domain)
id_lon =diag_axis_init('lon', lon, 'degrees_E', 'x', 'longitude', set_name=mod_name, Domain2=grid_domain, edges=id_lonb)
id_lat =diag_axis_init('lat', lat, 'degrees_N', 'y', 'latitude',  set_name=mod_name, Domain2=grid_domain, edges=id_latb)

call pressure_variables(p_half, ln_p_half, p_full, ln_p_full, reference_sea_level_press)
p_half = .01*p_half
p_full = .01*p_full
id_phalf = diag_axis_init('phalf',p_half,'hPa','z','approx half pressure level',direction=-1,set_name=mod_name)
id_pfull = diag_axis_init('pfull',p_full,'hPa','z','approx full pressure level',direction=-1,set_name=mod_name,edges=id_phalf)

axes_3d_half = (/ id_lon, id_lat, id_phalf /)
axes_3d_full = (/ id_lon, id_lat, id_pfull /)
axis_id(1) = id_lon
axis_id(2) = id_lat
axis_id(3) = id_pfull
axis_id(4) = id_phalf

id_pk = register_static_field(mod_name, 'pk', (/id_phalf/), 'vertical coordinate pressure values', 'pascals')
id_bk = register_static_field(mod_name, 'bk', (/id_phalf/), 'vertical coordinate sigma values', 'none')
id_zsurf = register_static_field(mod_name, 'zsurf', (/id_lon,id_lat/), 'geopotential height at the surface', 'm')

if(id_pk    > 0) used = send_data(id_pk, pk, Time)
if(id_bk    > 0) used = send_data(id_bk, bk, Time)
if(id_zsurf > 0) used = send_data(id_zsurf, surf_geopotential/grav, Time)

id_ps  = register_diag_field(mod_name, &
      'ps', (/id_lon,id_lat/),       Time, 'surface pressure',             'pascals')

id_u   = register_diag_field(mod_name, &
      'ucomp',   axes_3d_full,       Time, 'zonal wind component',         'm/sec',      range=vrange)

id_v   = register_diag_field(mod_name, &
      'vcomp',   axes_3d_full,       Time, 'meridional wind component',    'm/sec',      range=vrange)

id_uu  = register_diag_field(mod_name, &
      'ucomp_sq',axes_3d_full,       Time, 'zonal wind squared',           '(m/sec)**2', range=(/0.,vrange(2)**2/))

id_vv  = register_diag_field(mod_name, &
      'vcomp_sq',axes_3d_full,       Time, 'meridional wind squared',      '(m/sec)**2', range=(/0.,vrange(2)**2/))

id_uv  = register_diag_field(mod_name, &
      'ucomp_vcomp', axes_3d_full, Time, 'zonal wind * meridional wind', '(m/sec)**2', range=(/-vrange(2)**2,vrange(2)**2/))

id_omega_t = register_diag_field(mod_name, &
      'omega_temp',axes_3d_full,     Time, 'dp/dt * temperature',          'Pa*K/sec')

id_wspd= register_diag_field(mod_name, &
      'wspd',    axes_3d_full,       Time, 'wind speed',                   'm/sec',      range=(/0.,vrange(2)/))

id_t   = register_diag_field(mod_name, &
      'temp',    axes_3d_full,       Time, 'temperature',                  'deg_k',      range=trange)

id_tt  = register_diag_field(mod_name, &
      'temp_sq', axes_3d_full,       Time, 'temperature squared',          'deg_k**2',   range=(/0.,trange(2)**2/))

id_vor = register_diag_field(mod_name, &
      'vor',     axes_3d_full,       Time, 'vorticity',                    'sec**-1')

id_div = register_diag_field(mod_name, &
      'div',     axes_3d_full,       Time, 'divergence',                   'sec**-1')

id_div9 = register_diag_field(mod_name, &
      'div217',  (/id_lon,id_lat/),  Time, 'level 9 divergence',           'sec**-1')

id_omega = register_diag_field(mod_name, &
      'omega',   axes_3d_full,       Time, 'dp/dt vertical velocity',      'Pa/sec')

id_omega_omega = register_diag_field(mod_name, &
      'omega_sq',axes_3d_full,       Time, 'omega squared',                '(Pa/sec)**2')

id_pres_full = register_diag_field(mod_name, &
      'pres_full',    axes_3d_full,       Time, 'pressure at full model levels', 'pascals')

id_pres_half = register_diag_field(mod_name, &
      'pres_half',    axes_3d_half,       Time, 'pressure at half model levels', 'pascals')

id_zfull   = register_diag_field(mod_name, &
      'height',  axes_3d_full,       Time, 'geopotential height at full model levels','m')

id_zhalf   = register_diag_field(mod_name, &
      'height_half',  axes_3d_half,  Time, 'geopotential height at half model levels','m')

id_slp = register_diag_field(mod_name, &
      'slp',(/id_lon,id_lat/),       Time, 'sea level pressure',           'pascals')

if(id_slp > 0) then
  gamma = 0.006
  expf = rdgas*gamma/grav
  expf_inverse = 1./expf
endif

allocate(id_tr(num_tracers))
do ntr=1,num_tracers
  call get_tracer_names(MODEL_ATMOS, ntr, tname, longname, units)
  id_tr(ntr) = register_diag_field(mod_name, tname, axes_3d_full, Time, longname, units)
enddo

return
end subroutine spectral_diagnostics_init
!===================================================================================
subroutine spectral_diagnostics(Time, p_surf, u_grid, v_grid, t_grid, wg_full, tr_grid)

type(time_type), intent(in) :: Time
real, intent(in), dimension(is:ie, js:je)                          :: p_surf
real, intent(in), dimension(is:ie, js:je, num_levels)              :: u_grid, v_grid, t_grid, wg_full
real, intent(in), dimension(is:ie, js:je, num_levels, num_tracers) :: tr_grid

real, dimension(is:ie, js:je, num_levels)   :: ln_p_full, p_full, z_full, work
real, dimension(is:ie, js:je, num_levels+1) :: ln_p_half, p_half, z_half
real, dimension(is:ie, js:je)               :: t_low, slp
logical :: used
integer :: ntr, i, j, k, seconds, days
character(len=8) :: err_msg_1, err_msg_2

if(id_ps  > 0)    used = send_data(id_ps,  p_surf, Time)
if(id_u   > 0)    used = send_data(id_u,   u_grid, Time)
if(id_v   > 0)    used = send_data(id_v,   v_grid, Time)
if(id_t   > 0)    used = send_data(id_t,   t_grid, Time)
if(id_vor > 0)    used = send_data(id_vor, vorg, Time)
if(id_div > 0)    used = send_data(id_div, divg, Time)
if(id_omega > 0)  used = send_data(id_omega, wg_full, Time)
if(num_levels > 8 .and. id_div9 > 0) used = send_data(id_div9, divg(:,:,9), Time)

if(id_zfull > 0 .or. id_zhalf > 0) then
  call compute_pressures_and_heights(t_grid, p_surf, z_full, z_half, p_full, p_half)
else if(id_pres_half > 0 .or. id_pres_full > 0 .or. id_slp > 0) then
  call pressure_variables(p_half, ln_p_half, p_full, ln_p_full, p_surf)
endif

if(id_zfull > 0)   used = send_data(id_zfull,      z_full, Time)
if(id_zhalf > 0)   used = send_data(id_zhalf,      z_half, Time)
if(id_pres_full>0) used = send_data(id_pres_full,  p_full, Time)
if(id_pres_half>0) used = send_data(id_pres_half,  p_half, Time)

if(id_wspd > 0) then
  work = sqrt(u_grid**2 + v_grid**2)
  used = send_data(id_wspd, work, Time)
endif
if(id_uu > 0) then
  work = u_grid**2
  used = send_data(id_uu, work, Time)
endif
if(id_vv > 0) then
  work = v_grid**2
  used = send_data(id_vv, work, Time)
endif
if(id_uv > 0) then
  work = u_grid*v_grid
  used = send_data(id_uv, work, Time)
endif
if(id_tt > 0) then
  work = t_grid**2
  used = send_data(id_tt, work, Time)
endif
if(id_omega_omega > 0) then
  work = wg_full*wg_full
  used = send_data(id_omega_omega, work, Time)
endif
if(id_omega_t > 0) then
  work = wg_full*t_grid
  used = send_data(id_omega_t, work, Time)
endif

if(size(tr_grid,4) /= num_tracers) then
  write(err_msg_1,'(i8)') size(tr_grid,4)
  write(err_msg_2,'(i8)') num_tracers
  call error_mesg('spectral_diagnostics','size(tracers)='//err_msg_1//' Should be='//err_msg_2, FATAL)
endif
do ntr=1,num_tracers
  if(id_tr(ntr) > 0) used = send_data(id_tr(ntr), tr_grid(:,:,:,ntr), Time)
enddo

if(id_slp > 0) then
  do j=js,je
    do i=is,ie
      do k=1,num_levels
        if(p_full(i,j,k)/p_surf(i,j) > .8) goto 20
      enddo
      call error_mesg('spectral_diagnostics','No sigma values .gt. 0.8  Cannot compute slp',FATAL)
20    continue
      t_low(i,j) = t_grid(i,j,k)*(p_full(i,j,k)/p_surf(i,j))**(-expf)
      slp(i,j) = p_surf(i,j)*((t_low(i,j) + gamma*surf_geopotential(i,j)/grav)/t_low(i,j))**expf_inverse
    enddo
  enddo
  used = send_data(id_slp, slp, Time)
endif

if(interval_alarm(Time, Time_step, Alarm_time, Alarm_interval)) then
  call global_integrals(Time, p_surf, u_grid, v_grid, t_grid, wg_full, tr_grid)
endif

return
end subroutine spectral_diagnostics
!===================================================================================
subroutine global_integrals(Time, p_surf, u_grid, v_grid, t_grid, wg_full, tr_grid)
type(time_type), intent(in) :: Time
real, intent(in), dimension(is:ie, js:je)                          :: p_surf
real, intent(in), dimension(is:ie, js:je, num_levels)              :: u_grid, v_grid, t_grid, wg_full
real, intent(in), dimension(is:ie, js:je, num_levels, num_tracers) :: tr_grid
integer :: year, month, days, hours, minutes, seconds
character(len=4), dimension(12) :: month_name

month_name=(/' Jan',' Feb',' Mar',' Apr',' May',' Jun',' Jul',' Aug',' Sep',' Oct',' Nov',' Dec'/)

if(mpp_pe() == mpp_root_pe()) then
  if(get_calendar_type() == NO_CALENDAR) then
    call get_time(Time, seconds, days)
    write(*,100) days, seconds
  else
    call get_date(Time, year, month, days, hours, minutes, seconds)
    write(*,200) year, month_name(month), days, hours, minutes, seconds
  endif
endif
100 format(' Integration completed through',i6,' days',i6,' seconds')
200 format(' Integration completed through',i5,a4,i3,2x,i2,':',i2,':',i2)

end subroutine global_integrals
!===================================================================================
function get_axis_id()
integer, dimension(4) :: get_axis_id

if(.not.module_is_initialized) then
  call error_mesg('get_axis_id','spectral_diagnostics_init has not been called.', FATAL)
endif
get_axis_id = axis_id
return
end function get_axis_id
!===================================================================================
subroutine spectral_diagnostics_end

if(.not.module_is_initialized) return

deallocate(id_tr)

return
end subroutine spectral_diagnostics_end
!===================================================================================

end module spectral_dynamics_mod
