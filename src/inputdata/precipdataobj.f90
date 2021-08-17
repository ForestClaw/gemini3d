module precipdataobj

use, intrinsic :: ieee_arithmetic, only: ieee_is_finite
use phys_consts, only: wp,debug,pi
use inputdataobj, only: inputdata
use meshobj, only: curvmesh
use config, only: gemini_cfg
use reader, only: get_simsize2,get_grid2,get_precip
use mpimod, only: mpi_integer,mpi_comm_world,mpi_status_ignore,mpi_realprec,mpi_cfg,tag=>gemini_mpi
use timeutils, only: dateinc,date_filename

implicit none (type, external)

external :: mpi_send,mpi_recv
public :: precipdata

type, extends(inputdata) :: precipdata
  ! coordinate for input precipitation data, and storage
  real(wp), dimension(:), pointer :: mlonp,mlatp
  integer, pointer :: llon,llat
  real(wp), dimension(:,:), pointer :: Qp,E0p
  real(wp), dimension(:,:), pointer :: Qpiprev,E0piprev
  real(wp), dimension(:,:), pointer :: Qpinext,E0pinext
  real(wp), dimension(:,:), pointer :: Qpinow,E0pinow

  contains
    procedure :: init=>init_precip
    procedure :: set_coordsi=>set_coordsi_precip
    procedure :: load_data=>load_data_precip
    procedure :: load_grid=>load_grid_precip
    procedure :: load_size=>load_size_precip     ! load the size of the input data files
    final :: destructor
end type precipdata

contains
  !> set pointers to appropriate data arrays (taking into account dimensionality of the problem) and prime everything
  !    so we are ready to call self%update()
  !  After this procedure is called all pointer aliases are set and can be used; internal to this procedure pay attention
  !  to ordering of when pointers are set with respect to when various type-bound procedures are called
  subroutine init_precip(self,cfg,sourcedir,x,dtmodel,dtdata,ymd,UTsec)
    class(precipdata), intent(inout) :: self
    type(gemini_cfg), intent(in) :: cfg                 ! gemini config type for optional params
    character(*), intent(in) :: sourcedir    ! directory for precipitation data input
    class(curvmesh), intent(in) :: x                    ! curvmesh object
    real(wp), intent(in) :: dtmodel,dtdata                      ! model time step and cadence for input data from config.nml
    integer, dimension(3), intent(in) :: ymd            ! target date of initiation
    real(wp), intent(in) :: UTsec                       ! target time of initiation
    character(:), allocatable :: strname

    ! tell our object where its data are and give the dataset a name
    call self%set_source(sourcedir)
    strname='electron precipitation'
    call self%set_name(strname)

    ! read the simulation size from the source directory and allocate arrays
    allocate(self%lc1,self%lc2,self%lc3)
    self%llon=>self%lc2; self%llat=>self%lc3
    call self%load_size()
    call self%set_sizes(0, &
                       0,0,0, &
                       2,0,0, &
                       0, &
                       x )
    call self%init_storage()
    call self%set_cadence(dtdata)

    ! set local pointers grid pointers and assign input data grid
    self%mlonp=>self%coord2; self%mlatp=>self%coord3;
    call self%load_grid()

    ! set input data array pointers to faciliate easy to read input code; these may or may not be used
    self%Qp=>self%data2Dax23(:,:,1)
    self%E0p=>self%data2Dax23(:,:,2)
    self%Qpiprev=>self%data2Dax23i(:,:,1,1)
    self%Qpinext=>self%data2Dax23i(:,:,1,2)
    self%E0piprev=>self%data2Dax23i(:,:,2,1)
    self%E0pinext=>self%data2Dax23i(:,:,2,2)
    self%Qpinow=>self%data2Dax23inow(:,:,1)
    self%E0pinow=>self%data2Dax23inow(:,:,2)

    ! prime input data
    call self%prime_data(cfg,x,dtmodel,ymd,UTsec)
  end subroutine init_precip


  !> get the input grid size from file, all workers will just call this sicne this is a one-time thing
  subroutine load_size_precip(self)
    class(precipdata), intent(inout) :: self

    ! basic error checking
    if (.not. self%flagsource) error stop 'precipdata:load_size_precip() - must define a source directory first'

    ! read sizes
    print '(/,A,/,A)', 'Precipitation input:','--------------------'
    print '(A)', 'READ precipitation size from: ' // self%sourcedir
    call get_simsize2(self%sourcedir, llon=self%llon, llat=self%llat)

    print '(A,2I6)', 'Precipitation size: llon,llat:  ',self%llon,self%llat
    if (self%llon < 1 .or. self%llat < 1) then
     print*, '  precipitation grid size must be strictly positive: ' //  self%sourcedir
     error stop
    end if

    ! flag to denote input data size is set
    self%flagdatasize=.true.
  end subroutine load_size_precip


  !> get the grid information from a file, all workers will just call this since one-time
  subroutine load_grid_precip(self)
    class(precipdata), intent(inout) :: self

    ! read grid data
    call get_grid2(self%sourcedir, self%mlonp, self%mlatp)

    print '(A,4F9.3)', 'Precipitation mlon,mlat extent:  ',minval(self%mlonp(:)),maxval(self%mlonp(:)), &
                                                           minval(self%mlatp(:)),maxval(self%mlatp(:))
    if(.not. all(ieee_is_finite(self%mlonp))) error stop 'precipBCs_fileinput: mlon must be finite'
    if(.not. all(ieee_is_finite(self%mlatp))) error stop 'precipBCs_fileinput: mlat must be finite'
  end subroutine load_grid_precip


  subroutine set_coordsi_precip(self,cfg,x)
    class(precipdata), intent(inout) :: self
    type(gemini_cfg), intent(in) :: cfg     ! presently not used but possibly eventually?
    class(curvmesh), intent(in) :: x
    integer :: ix2,ix3,iflat

    do ix3=1,x%lx3
      do ix2=1,x%lx2
        iflat=(ix3-1)*x%lx2+ix2
        self%coord2i(iflat)=x%phi(x%lx1,ix2,ix3)*180._wp/pi
        self%coord3i(iflat)=90._wp - x%theta(x%lx1,ix2,ix3)*180._wp/pi
      end do
    end do

    self%flagcoordsi=.true.
  end subroutine set_coordsi_precip


  !> have root read in next input frame data and distribute to parallel workers
  subroutine load_data_precip(self,t,dtmodel)
    class(precipdata), intent(inout) :: self
    real(wp), intent(in) :: t,dtmodel

    integer, dimension(3) :: ymdtmp
    real(wp) :: UTsectmp
    integer :: iid,ierr

    !! this read must be done repeatedly through simulation so have only root do file io
    if (mpi_cfg%myid==0) then
      if(debug) print *, 'precipdata:load_data_precip() - tprev,tnow,tnext:  ',self%tref(1),t+dtmodel / 2._wp,self%tref(2)
      ! read in the data for the "next" frame from file
      ymdtmp = self%ymdref(:,2)
      UTsectmp = self%UTsecref(2)
      call dateinc(self%dt, ymdtmp, UTsectmp)
      call get_precip(date_filename(self%sourcedir,ymdtmp,UTsectmp), self%Qp, self%E0p)
  
      ! send a full copy of the data to all of the workers
      do iid=1,mpi_cfg%lid-1
        call mpi_send(self%Qp,self%llon*self%llat,mpi_realprec,iid,tag%Qp,MPI_COMM_WORLD,ierr)
        call mpi_send(self%E0p,self%llon*self%llat,mpi_realprec,iid,tag%E0p,MPI_COMM_WORLD,ierr)
      end do
    else
      ! workers receive data from root
      call mpi_recv(self%Qp,self%llon*self%llat,mpi_realprec,0,tag%Qp,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
      call mpi_recv(self%E0p,self%llon*self%llat,mpi_realprec,0,tag%E0p,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    end if
  end subroutine load_data_precip


  !> destructor needs to clear memory out
  subroutine destructor(self)
    type(precipdata), intent(inout) :: self

    call self%dissociate_pointers()
  end subroutine destructor
end module precipdataobj
