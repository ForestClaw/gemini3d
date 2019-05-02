module neutral
use, intrinsic:: iso_fortran_env, only: sp => real32

use mpi, only: mpi_integer, mpi_comm_world, mpi_status_ignore

use phys_consts, only: wp, lnchem, pi, re
use timeutils, only : doy_calc,dateinc
use grid, only: curvmesh, lx1, lx2, lx3, clear_unitvecs
use interpolation, only : interp2
use mpimod, only: myid, lid, taglrho, ierr, taglz, mpi_realprec, tagdno, tagdnn2, tagdno2, tagdtn, tagdvnrho, tagdvnz, tagly
use io, only : date_filename

implicit none

private


!! ALL ARRAYS THAT FOLLOW ARE USED WHEN INCLUDING NEUTRAL PERTURBATIONS FROM ANOTHER MODEL
!! ARRAYS TO STORE THE NEUTRAL GRID INFORMATION
real(wp), dimension(:), allocatable, private :: rhon    
!! as long as the neutral module is in scope these persist and do not require a "save"; this variable only used by the axisymmetric interpolation

real(wp), dimension(:), allocatable, private :: yn    
!! this variable only used in cartesian interpolation

real(wp), dimension(:), allocatable, private :: zn
integer, private :: lrhon,lzn,lyn


!! STORAGE FOR NEUTRAL SIMULATION DATA.  
!! THESE ARE INCLUDED AS MODULE VARIATIONS TO AVOID HAVING TO REALLOCATE AND DEALLOCIATE EACH TIME WE NEED TO INTERP
real(wp), dimension(:,:), allocatable, private :: dnO,dnN2,dnO2,dvnrho,dvnz,dTn    
!! assumed axisymmetric, so only 2D


!ARRAYS TO STORE NEUTRAL DATA THAT HAS BEEN INTERPOLATED
real(wp), dimension(:,:,:), allocatable, private :: dnOiprev,dnN2iprev,dnO2iprev,dvnrhoiprev,dvnziprev,dTniprev, &
                                                   dvn1iprev,dvn2iprev,dvn3iprev
real(wp), private :: tprev
integer, dimension(3), private :: ymdprev    
!! denoted time corresponding to "prev" interpolated data

real(wp), private :: UTsecprev
real(wp), dimension(:,:,:), allocatable, private :: dnOinext,dnN2inext,dnO2inext,dvnrhoinext,dvnzinext, &
                                                   dTninext,dvn1inext,dvn2inext,dvn3inext
real(wp), private :: tnext
integer, dimension(3), private :: ymdnext
real(wp), private :: UTsecnext


!SPACE TO STORE PROJECTION FACTORS
real(wp), dimension(:,:,:), allocatable, private :: proj_erhop_e1,proj_ezp_e1,proj_erhop_e2,proj_ezp_e2,proj_erhop_e3,proj_ezp_e3    !these projections are used in the axisymmetric interpolation
real(wp), dimension(:,:,:), allocatable, private :: proj_eyp_e1,proj_eyp_e2,proj_eyp_e3    !these are for Cartesian projections


!PLASMA GRID ZI AND RHOI LOCATIONS FOR INTERPOLATIONS
real(wp), dimension(:), allocatable, private :: zi,yi,rhoi    !this is to be a flat listing of sites on the, rhoi only used in axisymmetric and yi only in cartesian


!! BASE MSIS ATMOSPHERIC STATE ON WHICH TO APPLY PERTURBATIONS
real(wp), dimension(:,:,:,:), allocatable, protected :: nnmsis
real(wp), dimension(:,:,:), allocatable, protected :: Tnmsis
real(wp), dimension(:,:,:), allocatable, protected :: vn1base,vn2base,vn3base

public :: Tnmsis, neutral_atmos, make_dneu, clear_dneu, neutral_perturb,vn1base,vn2base,vn3base

contains

subroutine neutral_atmos(ymd,UTsecd,glat,glon,alt,activ,nn,Tn)

!------------------------------------------------------------
!-------CALL NRL-MSISE-00 AND ORGANIZE THE RESULTS.  APPEND
!-------OTHER AUXILIARY NEUTRAL DENSITY DATA USED BY MAIN
!-------CODE
!------------------------------------------------------------

integer, dimension(3) :: ymd
real(wp) :: UTsecd
real(wp), dimension(:,:,:), intent(in) :: glat,glon,alt
real(wp), dimension(3) :: activ

real(wp), dimension(1:size(alt,1),1:size(alt,2),1:size(alt,3),lnchem), intent(out) :: nn
real(wp), dimension(1:size(alt,1),1:size(alt,2),1:size(alt,3)), intent(out) :: Tn

integer :: ix1,ix2,ix3,lx1,lx2,lx3

integer :: iyd,mass=48
integer :: dom,month,year,doy,yearshort
real :: sec,f107a,f107,ap(7),stl,ap3
real :: altnow,latnow,lonnow
real :: d(9),t(2)

!   real(wp), dimension(1:size(alt,1),1:size(alt,2),1:size(alt,3)) :: nnow
!    real(wp), dimension(1:size(alt,1),1:size(alt,2),1:size(alt,3)) :: altalt    !an alternate altitude variable which fixes below ground values to 1km


lx1=size(alt,1)
lx2=size(alt,2)
lx3=size(alt,3)


!! CONVERT DATE INFO INTO EXPECTED FORM AND KIND
f107a=real(activ(1),sp)
f107=real(activ(2),sp)
ap=real(activ(3),sp)
ap3=real(activ(3),sp)
dom=ymd(3)
month=ymd(2)
year=ymd(1)
doy=doy_calc(ymd)
yearshort=mod(year,100)
iyd=yearshort*1000+doy
sec=floor(UTsecd)

ap(2)=ap3   !superfluous for now


!! ITERATED LAT, LON, ALT DATA
call meters(.true.)    !switch to mksa units

do ix3=1,lx3
  do ix2=1,lx2
    do ix1=1,lx1
      altnow=real(alt(ix1,ix2,ix3)/1d3,sp)
      if (altnow<0.0) then
        altnow = 1._sp     !so that MSIS does not get called with below ground values and so that we set them to something sensible that won't mess up the conductance calculations
      end if

      latnow=real(glat(ix1,ix2,ix3),sp)
      lonnow=real(glon(ix1,ix2,ix3),sp)

      stl=sec/3600.0+lonnow/15.0
      call gtd7(iyd,sec,altnow,latnow,lonnow,stl,f107a,f107,ap,mass,d,t)

      nn(ix1,ix2,ix3,1)=real(d(2),wp)
      nn(ix1,ix2,ix3,2)=real(d(3),wp)
      nn(ix1,ix2,ix3,3)=real(d(4),wp)
      nn(ix1,ix2,ix3,4)=real(d(7),wp)
      nn(ix1,ix2,ix3,5)=real(d(8),wp)

      Tn(ix1,ix2,ix3)=real(t(2),wp)
      nn(ix1,ix2,ix3,6)=4d-1*exp(-3700.0/Tn(ix1,ix2,ix3))*nn(ix1,ix2,ix3,3)+ &
                          5d-7*nn(ix1,ix2,ix3,1)   !Mitra, 1968
    end do
  end do
end do


!UPDATE THE REFERENCE ATMOSPHERE VALUES
nnmsis=nn; Tnmsis=Tn; 
!vn1base=0d0; vn2base=0d0; vn3base=0d0;
do ix3=1,lx3
  do ix2=1,lx2
    do ix1=1,lx1
      !vn1base(ix1,ix2,ix3)=-10d0*(0.5d0+0.5d0*tanh((alt(ix1,ix2,ix3)-150d3)/10d3))
      vn1base(ix1,ix2,ix3)=0d0
      vn2base(ix1,ix2,ix3)=-100d0*(0.5d0+0.5d0*tanh((alt(ix1,ix2,ix3)-150d3)/10d3))
      vn3base(ix1,ix2,ix3)=120d0*(0.5d0+0.5d0*tanh((alt(ix1,ix2,ix3)-150d3)/10d3))
    end do
  end do
end do

end subroutine neutral_atmos


!THIS IS  WRAPPER FOR THE NEUTRAL PERTURBATION CODES THAT DO EITHER
!AXISYMMETRIC OR CARTESIAN INTEGRATION
subroutine neutral_perturb(interptype,dt,dtneu,t,ymd,UTsec,neudir,drhon,dzn,meanlat,meanlong,x,nn,Tn,vn1,vn2,vn3)

integer, intent(in) :: interptype
real(wp), intent(in) :: dt,dtneu
real(wp), intent(in) :: t
integer, dimension(3), intent(in) :: ymd    !date for which we wish to calculate perturbations
real(wp), intent(in) :: UTsec
real(wp), intent(in) :: drhon,dzn         !neutral grid spacing
real(wp), intent(in) :: meanlat, meanlong    !neutral source center location
character(*), intent(in) :: neudir       !directory where neutral simulation data is kept

type(curvmesh), intent(inout) :: x         !grid structure  (inout becuase we want to be able to deallocate unit vectors once we are done with them)
real(wp), dimension(:,:,:,:), intent(out) :: nn   !neutral params interpolated to plasma grid at requested time
real(wp), dimension(:,:,:), intent(out) :: Tn,vn1,vn2,vn3

if (interptype==0) then    !cartesian interpolation drho inputs (radial distance) will be interpreted as dy (horizontal distance)
  call neutral_perturb_cart(dt,dtneu,t,ymd,UTsec,neudir,drhon,dzn,meanlat,meanlong,x,nn,Tn,vn1,vn2,vn3)
else     !axisymmetric interpolation
  call neutral_perturb_axisymm(dt,dtneu,t,ymd,UTsec,neudir,drhon,dzn,meanlat,meanlong,x,nn,Tn,vn1,vn2,vn3)
end if

end subroutine neutral_perturb


!FOR CONSISTENCY I'D LIKE TO STRUCTURE NEUTRAL PERTURB OPERATIONS LIKE GRAVITY IS HANDLED IN THE GRID MODULE, I.E. HAVE AN EXPLICIT CONSTRUCTORS/DESTRUCTOR TYPE ROUTINE THAT HANDLES ALLOCATION AND DEALLOCATION, WHICH WILL CLEAN UP THE NEUTRAL_PERTURB SUBROUTINE, I.E. REMOVE ALLOCATES OF PERSISTENT MODULE VARIABLES.  
subroutine neutral_perturb_axisymm(dt,dtneu,t,ymd,UTsec,neudir,drhon,dzn,meanlat,meanlong,x,nn,Tn,vn1,vn2,vn3)

!------------------------------------------------------------
!-------COMPUTE NEUTRAL PERTURBATIONS FOR THIS TIME STEP.  ADD
!-------THEM TO MSIS PERTURBATIONS TO GET ABSOLUTE VALUES FOR
!-------EACH PARAMETER
!-------
!-------THIS VERSION ASSUMES THE INPUT NEUTRAL DATA ARE IN 
!-------CYLINDRICAL COORDINATES.
!------------------------------------------------------------

real(wp), intent(in) :: dt,dtneu
real(wp), intent(in) :: t
integer, dimension(3), intent(in) :: ymd    !date for which we wish to calculate perturbations
real(wp), intent(in) :: UTsec
real(wp), intent(in) :: drhon,dzn         !neutral grid spacing
real(wp), intent(in) :: meanlat, meanlong    !neutral source center location
character(*), intent(in) :: neudir       !directory where neutral simulation data is kept

type(curvmesh), intent(inout) :: x         !grid structure  (inout becuase we want to be able to deallocate unit vectors once we are done with them)
real(wp), dimension(:,:,:,:), intent(out) :: nn   !neutral params interpolated to plasma grid at requested time
real(wp), dimension(:,:,:), intent(out) :: Tn,vn1,vn2,vn3

integer, parameter :: inunit=46          !file handle for various input files
character(512) :: filename               !space to store filenames, note size must be 512 to be consistent with our date_ffilename functinos
real(wp) :: theta1,phi1,theta2,phi2,gammarads,theta3,phi3,gamma1,gamma2,phip
real(wp) :: xp,yp
real(wp), dimension(3) :: erhop,ezp,tmpvec

real(wp) :: tmpsca

integer :: ix1,ix2,ix3,irhon,izn,iid
real(wp), dimension(size(nn,1),size(nn,2),size(nn,3)) :: zimat,rhoimat
integer, dimension(3) :: ymdtmp
real(wp) :: UTsectmp
real(wp), dimension(size(nn,1)*size(nn,2)*size(nn,3)) :: parami
real(wp) :: slope
real(wp), dimension(size(nn,1),size(nn,2),size(nn,3)) :: dnOinow,dnN2inow,dnO2inow,dTninow,dvn1inow,dvn2inow,dvn3inow    !current time step perturbations (centered in time)

integer(4) :: flaginit    !a flag that is set during the first call to read in data

integer :: utrace


!CHECK WHETHER WE NEED TO LOAD A NEW FILE
if (t+dt/2d0>=tnext .or. t<=0d0) then   !negative time means that we need to load the first frame
  !IF FIRST LOAD ATTEMPT CREATE A NEUTRAL GRID AND COMPUTE GRID SITES FOR IONOSPHERIC GRID.  Since this needs an input file, I'm leaving it under this condition here
  if (.not. allocated(rhon)) then     !means this is the first tiem we've tried to load neutral simulation data, should we check for a previous neutral file to load??? or just assume everything starts at zero?  This needs to somehow check for an existing file under certain conditiosn, maybe if it==1???  Actually we don't even need that we can just check that the neutral grid is allocated (or not)
    !initialize dates
    ymdprev=ymd
    UTsecprev=UTsec
    ymdnext=ymdprev
    UTsecnext=UTsecprev
    if (myid==0) then    !root
      write(filename,*) trim(adjustl(neudir)),'simsize.dat'
      print *, 'Inputting neutral size from file:  ',trim(adjustl(filename))
      open(inunit,file=trim(adjustl(filename)),status='old',form='unformatted',access='stream')
      read(inunit) lrhon,lzn
      close(inunit)
      print *, 'Neutral data has lrho,lz size:  ',lrhon,lzn,' with spacing drho,dz',drhon,dzn

      do iid=1,lid-1
        call mpi_send(lrhon,1,MPI_INTEGER,iid,taglrho,MPI_COMM_WORLD,ierr)
        call mpi_send(lzn,1,MPI_INTEGER,iid,taglz,MPI_COMM_WORLD,ierr)
      end do
    else     !workers
      call mpi_recv(lrhon,1,MPI_INTEGER,0,taglrho,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
      call mpi_recv(lzn,1,MPI_INTEGER,0,taglz,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    end if
    !Everyone need a copy of the grid
    allocate(rhon(lrhon),zn(lzn))    !these are module-scope variables
    allocate(yn(1))    !not used in the axisymmetric code so just initialize to something
    allocate(dnO(lzn,lrhon),dnN2(lzn,lrhon),dnO2(lzn,lrhon),dvnrho(lzn,lrhon),dvnz(lzn,lrhon),dTn(lzn,lrhon))

    !Define a grid
    rhon=[ ((real(irhon,8)-1._wp)*drhon, irhon=1,lrhon) ]
!        rhon=rhon+0.5d0*drhon       !to convert to cell-centered (can lead to some interpolation artifacts, for reasons that are unclear - need to revisit)
    zn=[ ((real(izn,8)-1._wp)*dzn, izn=1,lzn) ]
!        zn=zn+0.5d0*dzn             !cell-center
    if (myid==0) then
      print *, 'Creating neutral grid with rho,z extent:  ',minval(rhon),maxval(rhon),minval(zn),maxval(zn)
    end if

    
    !neutral source locations specified in input file, here referenced by spherical magnetic coordinates.  
    phi1=meanlong*pi/180d0
    theta1=pi/2d0-meanlat*pi/180d0

    !convert plasma grid locations to z,rho values to be used in interoplation.  altitude ~ zi; lat/lon --> rhoi.  Also compute unit vectors and projections
    if (myid==0) then
      print *, 'Computing alt,radial distance values for plasma grid and completing rotations'
    end if
    zimat=x%alt     !vertical coordinate
    do ix3=1,lx3
      do ix2=1,lx2
        do ix1=1,lx1
!              !INTERPOLATION BASED ON GEOGRAPHIC COORDINATES (CREATES ISSUES IN 2D BUT LEFT HERE IN CASE IT'S USEFUL FOR SOME APPLICATION)
!              theta2=pi/2d0-x%glat(ix1,ix2,ix3)*pi/180d0    !field point zenith angle
!              if (lx2/=1) then
!                phi2=x%glon(ix1,ix2,ix3)*pi/180d0             !field point azimuth, full 3D calculation
!              else
!                phi2=phi1                                     !assume the longitude is the samem as the source in 2D, i.e. assume the source epicenter is in the meridian of the grid
!!                phi2=x%glon(ix1,ix2,ix3)*pi/180d0     !doesn't seem to make any difference
!              end if


          !INTERPOLATION BASED ON GEOMAGNETIC COORDINATES
          theta2=x%theta(ix1,ix2,ix3)                    !field point zenith angle
          if (lx2/=1) then
            phi2=x%phi(ix1,ix2,ix3)                      !field point azimuth, full 3D calculation
          else
            phi2=phi1                                    !assume the longitude is the samem as the source in 2D, i.e. assume the source epicenter is in the meridian of the grid
          end if



          !COMPUTE DISTANCES
          gammarads=cos(theta1)*cos(theta2)+sin(theta1)*sin(theta2)*cos(phi1-phi2)     !this is actually cos(gamma)
          if (gammarads>1._wp) then     !handles weird precision issues in 2D
            gammarads=1._wp
          else if (gammarads<-1._wp) then
            gammarads=-1._wp
          end if
          gammarads=acos(gammarads)                     !angle between source location annd field point (in radians)
          rhoimat(ix1,ix2,ix3)=Re*gammarads    !rho here interpreted as the arc-length defined by angle between epicenter and ``field point''

          !we need a phi locationi (not spherical phi, but azimuth angle from epicenter), as well, but not for interpolation - just for doing vector rotations
          theta3=theta2
          phi3=phi1
          gamma1=cos(theta2)*cos(theta3)+sin(theta2)*sin(theta3)*cos(phi2-phi3)
          if (gamma1>1._wp) then     !handles weird precision issues in 2D
            gamma1=1._wp
          else if (gamma1<-1._wp) then
            gamma1=-1._wp
          end if
          gamma1=acos(gamma1)

          gamma2=cos(theta1)*cos(theta3)+sin(theta1)*sin(theta3)*cos(phi1-phi3)
          if (gamma2>1._wp) then     !handles weird precision issues in 2D
            gamma2=1._wp
          else if (gamma2<-1._wp) then
            gamma2=-1._wp
          end if
          gamma2=acos(gamma2)
          xp=Re*gamma1
          yp=Re*gamma2     !this will likely always be positive, since we are using center of earth as our origin, so this should be interpreted as distance as opposed to displacement


          !COMPUTE COORDIANTES FROM DISTANCES
          if (theta3>theta1) then       !place distances in correct quadrant, here field point (theta3=theta2) is is SOUTHward of source point (theta1), whreas yp is distance northward so throw in a negative sign
            yp=-1._wp*yp            !do we want an abs here to be safe
          end if
          if (phi2<phi3) then     !assume we aren't doing a global grid otherwise need to check for wrapping, here field point (phi2) less than soure point (phi3=phi1)
            xp=-1._wp*xp
          end if
          phip=atan2(yp,xp)


          !PROJECTIONS FROM NEUTURAL GRID VECTORS TO PLASMA GRID VECTORS
          !projection factors for mapping from axisymmetric to dipole (go ahead and compute projections so we don't have to do it repeatedly as sim runs
          erhop=cos(phip)*x%e3(ix1,ix2,ix3,:)+(-1._wp)*sin(phip)*x%etheta(ix1,ix2,ix3,:)     !unit vector for azimuth (referenced from epicenter - not geocenter!!!) in cartesian geocentric-geomagnetic coords.
          ezp=x%er(ix1,ix2,ix3,:)

          tmpvec=erhop*x%e1(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_erhop_e1(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e1(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_ezp_e1(ix1,ix2,ix3)=tmpsca

          tmpvec=erhop*x%e2(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_erhop_e2(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e2(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_ezp_e2(ix1,ix2,ix3)=tmpsca

          tmpvec=erhop*x%e3(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_erhop_e3(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e3(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)    !should be zero, but leave it general for now
          proj_ezp_e3(ix1,ix2,ix3)=tmpsca
        end do
      end do
    end do
    zi=pack(zimat,.true.)     !create a flat list of grid points to be used by interpolation ffunctions
    rhoi=pack(rhoimat,.true.)


    !GRID UNIT VECTORS NO LONGER NEEDED ONCE PROJECTIONS ARE CALCULATED...
    call clear_unitvecs(x)


    !PRINT OUT SOME BASIC INFO ABOUT THE GRID THAT WE'VE LOADED
    if (myid==0) then
      print *, 'Min/max rhon,zn values',minval(rhon),maxval(rhon),minval(zn),maxval(zn)
      print *, 'Min/max rhoi,zi values',minval(rhoi),maxval(rhoi),minval(zi),maxval(zi)
      print *, 'Source lat/long:  ',meanlat,meanlong
      print *, 'Plasma grid lat range:  ',minval(x%glat(:,:,:)),maxval(x%glat(:,:,:))
      print *, 'Plasma grid lon range:  ',minval(x%glon(:,:,:)),maxval(x%glon(:,:,:))
    end if
  end if


  !ALL THE NECESSARY ARRAYS EXIST AT THIS POINT, SO GO AHEAD AND READ IN THE DATA - only root should do this and then distribute to the workers
  if (myid==0) then    !root
    !read in the data from file
    print *, 'tprev,tnow,tnext:  ',tprev,t+dt/2d0,tnext
    ymdtmp=ymdnext
    UTsectmp=UTsecnext
    call dateinc(dtneu,ymdtmp,UTsectmp)    !get the date for "next" params
    filename=date_filename(neudir,ymdtmp,UTsectmp)     !form the standard data filename
    print *, 'Pulling neutral data from file:  ',trim(adjustl(filename))
    open(inunit,file=trim(adjustl(filename)),status='old',form='unformatted',access='stream')
    read(inunit) dnO,dnN2,dnO2,dvnrho,dvnz,dTn
    close(inunit)

    print *, 'Min/max values for dnO:  ',minval(dnO),maxval(dnO)
    print *, 'Min/max values for dnN:  ',minval(dnN2),maxval(dnN2)
    print *, 'Min/max values for dnO:  ',minval(dnO2),maxval(dnO2)
    print *, 'Min/max values for dvnrho:  ',minval(dvnrho),maxval(dvnrho)
    print *, 'Min/max values for dvnz:  ',minval(dvnz),maxval(dvnz)
    print *, 'Min/max values for dTn:  ',minval(dTn),maxval(dTn)

    !send a full copy of the data to all of the workers
    do iid=1,lid-1
      call mpi_send(dnO,lrhon*lzn,mpi_realprec,iid,tagdnO,MPI_COMM_WORLD,ierr)
      call mpi_send(dnN2,lrhon*lzn,mpi_realprec,iid,tagdnN2,MPI_COMM_WORLD,ierr)
      call mpi_send(dnO2,lrhon*lzn,mpi_realprec,iid,tagdnO2,MPI_COMM_WORLD,ierr)
      call mpi_send(dTn,lrhon*lzn,mpi_realprec,iid,tagdTn,MPI_COMM_WORLD,ierr)
      call mpi_send(dvnrho,lrhon*lzn,mpi_realprec,iid,tagdvnrho,MPI_COMM_WORLD,ierr)
      call mpi_send(dvnz,lrhon*lzn,mpi_realprec,iid,tagdvnz,MPI_COMM_WORLD,ierr)
    end do
  else     !workers
    !receive a full copy of the data from root
    call mpi_recv(dnO,lrhon*lzn,mpi_realprec,0,tagdnO,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dnN2,lrhon*lzn,mpi_realprec,0,tagdnN2,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dnO2,lrhon*lzn,mpi_realprec,0,tagdnO2,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dTn,lrhon*lzn,mpi_realprec,0,tagdTn,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dvnrho,lrhon*lzn,mpi_realprec,0,tagdvnrho,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dvnz,lrhon*lzn,mpi_realprec,0,tagdvnz,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
  end if


  !DO SPATIAL INTERPOLATION OF EACH PARAMETER (COULD CONSERVE SOME MEMORY BY NOT STORING DVNRHOIPREV AND DVNRHOINEXT, ETC.)
  if (myid==0) then
    print *, 'Initiating spatial interpolations for date:  ',ymdtmp,' ',UTsectmp
  end if
  parami=interp2(zn,rhon,dnO,zi,rhoi)     !interp to temp var.
  dnOiprev=dnOinext                       !save new pervious
  dnOinext=reshape(parami,[lx1,lx2,lx3])    !overwrite next with new interpolated input

  parami=interp2(zn,rhon,dnN2,zi,rhoi)
  dnN2iprev=dnN2inext
  dnN2inext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,rhon,dnN2,zi,rhoi)
  dnO2iprev=dnO2inext
  dnO2inext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,rhon,dvnrho,zi,rhoi)
  dvnrhoiprev=dvnrhoinext
  dvnrhoinext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,rhon,dvnz,zi,rhoi)
  dvnziprev=dvnzinext
  dvnzinext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,rhon,dTn,zi,rhoi)
  dTniprev=dTninext
  dTninext=reshape(parami,[lx1,lx2,lx3])

!
!  !MORE DIAG
!  if (myid==lid/2) then
!    print *, 'Min/max values for dnOi:  ',minval(dnOinext),maxval(dnOinext)
!    print *, 'Min/max values for dnN2i:  ',minval(dnN2inext),maxval(dnN2inext)
!    print *, 'Min/max values for dnO2i:  ',minval(dnO2inext),maxval(dnO2inext)
!    print *, 'Min/max values for dvrhoi:  ',minval(dvnrhoinext),maxval(dvnrhoinext)
!    print *, 'Min/max values for dvnzi:  ',minval(dvnzinext),maxval(dvnzinext)
!    print *, 'Min/max values for dTni:  ',minval(dTninext),maxval(dTninext)
!  end if
!

  !ROTATE VECTORS INTO X1 X2 DIRECTIONS (Need to include unit vectors with grid structure)
  if (myid==0) then
    print *, 'Rotating vectors for date:  ',ymdtmp,' ',UTsectmp
  end if

  dvn1iprev=dvn1inext   !save the old data
  dvn1inext=dvnrhoinext*proj_erhop_e1+dvnzinext*proj_ezp_e1    !apply projection to complete rotation into dipole coordinates

  dvn2iprev=dvn2inext
  dvn2inext=dvnrhoinext*proj_erhop_e2+dvnzinext*proj_ezp_e2

  dvn3iprev=dvn3inext
  dvn3inext=dvnrhoinext*proj_erhop_e3+dvnzinext*proj_ezp_e3


  !MORE DIAGNOSTICS
  if (myid==lid/2) then
    print *, 'Min/max values for dnOi:  ',minval(dnOinext),maxval(dnOinext)
    print *, 'Min/max values for dnN2i:  ',minval(dnN2inext),maxval(dnN2inext)
    print *, 'Min/max values for dnO2i:  ',minval(dnO2inext),maxval(dnO2inext)
    print *, 'Min/max values for dvn1i:  ',minval(dvn1inext),maxval(dvn1inext)
    print *, 'Min/max values for dvn2i:  ',minval(dvn2inext),maxval(dvn2inext)
    print *, 'Min/max values for dvn3i:  ',minval(dvn3inext),maxval(dvn3inext)
    print *, 'Min/max values for dTni:  ',minval(dTninext),maxval(dTninext)
  end if


  !UPDATE OUR CONCEPT OF PREVIOUS AND NEXT TIMES
  tprev=tnext
  UTsecprev=UTsecnext
  ymdprev=ymdnext

  tnext=tprev+dtneu
  UTsecnext=UTsectmp
  ymdnext=ymdtmp
end if


!(NOW) DO LINEAR INTERPOLATION IN TIME
do ix3=1,lx3
  do ix2=1,lx2
    do ix1=1,lx1
      slope=(dnOinext(ix1,ix2,ix3)-dnOiprev(ix1,ix2,ix3))/(tnext-tprev)
      dnOinow(ix1,ix2,ix3)=dnOiprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dnN2inext(ix1,ix2,ix3)-dnN2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dnN2inow(ix1,ix2,ix3)=dnN2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dnO2inext(ix1,ix2,ix3)-dnO2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dnO2inow(ix1,ix2,ix3)=dnO2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn1inext(ix1,ix2,ix3)-dvn1iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn1inow(ix1,ix2,ix3)=dvn1iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn2inext(ix1,ix2,ix3)-dvn2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn2inow(ix1,ix2,ix3)=dvn2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn3inext(ix1,ix2,ix3)-dvn3iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn3inow(ix1,ix2,ix3)=dvn3iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dTninext(ix1,ix2,ix3)-dTniprev(ix1,ix2,ix3))/(tnext-tprev)
      dTninow(ix1,ix2,ix3)=dTniprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev) 
    end do
  end do
end do


!SOME BASIC DIAGNOSTICS
if (myid==lid/2) then
  print *, myid
  print *, 'tprev,t,tnext:  ',tprev,t+dt/2d0,tnext
  print *, 'Min/max values for dnOinow:  ',minval(dnOinow),maxval(dnOinow)
  print *, 'Min/max values for dnN2inow:  ',minval(dnN2inow),maxval(dnN2inow)
  print *, 'Min/max values for dnO2inow:  ',minval(dnO2inow),maxval(dnO2inow)
  print *, 'Min/max values for dvn1inow:  ',minval(dvn1inow),maxval(dvn1inow)
  print *, 'Min/max values for dvn2inow:  ',minval(dvn2inow),maxval(dvn2inow)
  print *, 'Min/max values for dvn3inow:  ',minval(dvn3inow),maxval(dvn3inow)
  print *, 'Min/max values for dTninow:  ',minval(dTninow),maxval(dTninow)
end if


!NOW UPDATE THE PROVIDED NEUTRAL ARRAYS
nn(:,:,:,1)=nnmsis(:,:,:,1)+dnOinow
nn(:,:,:,2)=nnmsis(:,:,:,2)+dnN2inow
nn(:,:,:,3)=nnmsis(:,:,:,3)+dnO2inow 
nn(:,:,:,1)=max(nn(:,:,:,1),1._wp)
nn(:,:,:,2)=max(nn(:,:,:,2),1._wp)
nn(:,:,:,3)=max(nn(:,:,:,3),1._wp)
Tn=Tnmsis+dTninow
Tn=max(Tn,50._wp)
vn1=vn1base+dvn1inow
vn2=vn2base+dvn2inow
vn3=vn3base+dvn3inow

end subroutine neutral_perturb_axisymm


!! THIS SHARES SO MUCH CODE WITH THE AXISYMMETRIC VERSION THAT THEY SHOULD PROBABLY BE COMBINED
subroutine neutral_perturb_cart(dt,dtneu,t,ymd,UTsec,neudir,dyn,dzn,meanlat,meanlong,x,nn,Tn,vn1,vn2,vn3)

!------------------------------------------------------------
!-------COMPUTE NEUTRAL PERTURBATIONS FOR THIS TIME STEP.  ADD
!-------THEM TO MSIS PERTURBATIONS TO GET ABSOLUTE VALUES FOR
!-------EACH PARAMETER.
!-------
!-------THIS VERSION ASSUMES THE INPUT NEUTRAL DATA ARE IN 
!-------CARTESIAN COORDINATES.
!------------------------------------------------------------

real(wp), intent(in) :: dt,dtneu
real(wp), intent(in) :: t
integer, dimension(3), intent(in) :: ymd    !date for which we wish to calculate perturbations
real(wp), intent(in) :: UTsec
real(wp), intent(in) :: dyn,dzn         !neutral grid spacing
real(wp), intent(in) :: meanlat, meanlong    !neutral source center location
character(*), intent(in) :: neudir       !directory where neutral simulation data is kept

type(curvmesh), intent(inout) :: x         !grid structure  (inout becuase we want to be able to deallocate unit vectors once we are done with them)
real(wp), dimension(:,:,:,:), intent(out) :: nn   !neutral params interpolated to plasma grid at requested time
real(wp), dimension(:,:,:), intent(out) :: Tn,vn1,vn2,vn3

integer, parameter :: inunit=46          !file handle for various input files
character(512) :: filename               !space to store filenames, note size must be 512 to be consistent with our date_ffilename functinos
real(wp) :: theta1,phi1,theta2,phi2,gammarads,theta3,phi3,gamma1,gamma2,phip
real(wp) :: xp,yp
real(wp), dimension(3) :: erhop,ezp,eyp,tmpvec

real(wp) :: tmpsca
real(wp) :: meanyn

integer :: ix1,ix2,ix3,iyn,izn,iid
real(wp), dimension(size(nn,1),size(nn,2),size(nn,3)) :: zimat,rhoimat,yimat
integer, dimension(3) :: ymdtmp
real(wp) :: UTsectmp
real(wp), dimension(size(nn,1)*size(nn,2)*size(nn,3)) :: parami
real(wp) :: slope
real(wp), dimension(size(nn,1),size(nn,2),size(nn,3)) :: dnOinow,dnN2inow,dnO2inow,dTninow,dvn1inow,dvn2inow,dvn3inow    !current time step perturbations (centered in time)


!CHECK WHETHER WE NEED TO LOAD A NEW FILE
if (t+dt/2d0>=tnext) then
  !IF FIRST LOAD ATTEMPT CREATE A NEUTRAL GRID AND COMPUTE GRID SITES FOR IONOSPHERIC GRID.  Since this needs an input file, I'm leaving it under this condition here
  if (.not. allocated(rhon)) then     !means this is the first tiem we've tried to load neutral simulation data, should we check for a previous neutral file to load???
    !initialize dates
    ymdprev=ymd
    UTsecprev=UTsec
    ymdnext=ymdprev
    UTsecnext=UTsecprev
    if (myid==0) then    !root
      write(filename,*) trim(adjustl(neudir)),'simsize.dat'
      print *, 'Inputting neutral size from file:  ',trim(adjustl(filename))
      open(inunit,file=trim(adjustl(filename)),status='old',form='unformatted',access='stream')
      read(inunit) lyn,lzn
      close(inunit)
      print *, 'Neutral data has ly,lz size:  ',lyn,lzn,' with spacing dy,dz',dyn,dzn

      do iid=1,lid-1
        call mpi_send(lyn,1,MPI_INTEGER,iid,tagly,MPI_COMM_WORLD,ierr)
        call mpi_send(lzn,1,MPI_INTEGER,iid,taglz,MPI_COMM_WORLD,ierr)
      end do
    else     !workers
      call mpi_recv(lyn,1,MPI_INTEGER,0,tagly,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
      call mpi_recv(lzn,1,MPI_INTEGER,0,taglz,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    end if
    !Everyone need a copy of the grid
    allocate(yn(lyn),zn(lzn))    !these are module-scope variables
    allocate(rhon(1))    !not used in the axisymmetric code so just initialize to something
    allocate(dnO(lzn,lyn),dnN2(lzn,lyn),dnO2(lzn,lyn),dvnrho(lzn,lyn),dvnz(lzn,lyn),dTn(lzn,lyn))

    !Define a grid
    yn=[ ((real(iyn,8)-1._wp)*dyn, iyn=1,lyn) ]
    meanyn=sum(yn,1)/size(yn,1)
    yn=yn-meanyn     !the neutral grid should be centered on zero for a cartesian interpolation
!        rhon=rhon+0.5d0*drhon       !to convert to cell-centered (can lead to some interpolation artifacts...
    zn=[ ((real(izn,8)-1._wp)*dzn, izn=1,lzn) ]
!        zn=zn+0.5d0*dzn             !cell-center
    if (myid==0) then
      print *, 'Creating neutral grid with y,z extent:  ',minval(yn),maxval(yn),minval(zn),maxval(zn)
    end if

    
    !neutral source locations specified in input file, here referenced by spherical coordinates (magnetic).
    phi1=meanlong*pi/180d0
    theta1=pi/2d0-meanlat*pi/180d0


    !convert plasma grid locations to z,y values to be used in interoplation.  altitude ~ zi; north dist. --> yi.  Also compute unit vectors and projections
    if (myid==0) then
      print *, 'Computing alt,radial distance values for plasma grid and completing rotations'
    end if
    zimat=x%alt     !vertical coordinate
    do ix3=1,lx3
      do ix2=1,lx2
        do ix1=1,lx1
          !INTERPOLATION BASED ON GEOMAGNETIC COORDINATES
          theta2=x%theta(ix1,ix2,ix3)                    !field point zenith angle
          if (lx2/=1) then
            phi2=x%phi(ix1,ix2,ix3)                      !field point azimuth, full 3D calculation
          else
            phi2=phi1                                    !assume the longitude is the samem as the source in 2D, i.e. assume the source epicenter is in the meridian of the grid
          end if



          !COMPUTE DISTANCES
          gammarads=cos(theta1)*cos(theta2)+sin(theta1)*sin(theta2)*cos(phi1-phi2)     !this is actually cos(gamma)
          if (gammarads>1._wp) then     !handles weird precision issues in 2D
            gammarads=1._wp
          else if (gammarads<-1._wp) then
            gammarads=-1._wp
          end if
          gammarads=acos(gammarads)                     !angle between source location annd field point (in radians)
          rhoimat(ix1,ix2,ix3)=Re*gammarads    !rho here interpreted as the arc-length defined by angle between epicenter and ``field point''

          !we need a phi locationi (not spherical phi, but azimuth angle from epicenter), as well, but not for interpolation - just for doing vector rotations
          theta3=theta2
          phi3=phi1
          gamma1=cos(theta2)*cos(theta3)+sin(theta2)*sin(theta3)*cos(phi2-phi3)
          if (gamma1>1._wp) then     !handles weird precision issues in 2D
            gamma1=1._wp
          else if (gamma1<-1._wp) then
            gamma1=-1._wp
          end if
          gamma1=acos(gamma1)

          gamma2=cos(theta1)*cos(theta3)+sin(theta1)*sin(theta3)*cos(phi1-phi3)
          if (gamma2>1._wp) then     !handles weird precision issues in 2D
            gamma2=1._wp
          else if (gamma2<-1._wp) then
            gamma2=-1._wp
          end if
          gamma2=acos(gamma2)
          xp=Re*gamma1
          yp=Re*gamma2     !this will likely always be positive, since we are using center of earth as our origin, so this should be interpreted as distance as opposed to displacement


          !COMPUTE COORDIANTES FROM DISTANCES
          if (theta3>theta1) then       !place distances in correct quadrant, here field point (theta3=theta2) is is SOUTHward of source point (theta1), whreas yp is distance northward so throw in a negative sign
            yp=-1._wp*yp            !do we want an abs here to be safe
          end if
          if (phi2<phi3) then     !assume we aren't doing a global grid otherwise need to check for wrapping, here field point (phi2) less than soure point (phi3=phi1)
            xp=-1._wp*xp
          end if
          phip=atan2(yp,xp)


          !STORE CARESIAN DISTANCES, AS WELL
          yimat(ix1,ix2,ix3)=yp


          !PROJECTIONS FROM NEUTURAL GRID VECTORS TO PLASMA GRID VECTORS
          !projection factors for mapping from axisymmetric to dipole (go ahead and compute projections so we don't have to do it repeatedly as sim runs
          ezp=x%er(ix1,ix2,ix3,:)
          eyp=-1._wp*x%etheta(ix1,ix2,ix3,:)

          tmpvec=eyp*x%e1(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_eyp_e1(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e1(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_ezp_e1(ix1,ix2,ix3)=tmpsca

          tmpvec=eyp*x%e2(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_eyp_e2(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e2(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_ezp_e2(ix1,ix2,ix3)=tmpsca

          tmpvec=eyp*x%e3(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)
          proj_eyp_e3(ix1,ix2,ix3)=tmpsca

          tmpvec=ezp*x%e3(ix1,ix2,ix3,:)
          tmpsca=sum(tmpvec)    !should be zero, but leave it general for now
          proj_ezp_e3(ix1,ix2,ix3)=tmpsca
        end do
      end do
    end do
    zi=pack(zimat,.true.)     !create a flat list of grid points to be used by interpolation ffunctions
    rhoi=pack(rhoimat,.true.)
    yi=pack(yimat,.true.)


    !GRID UNIT VECTORS NO LONGER NEEDED ONCE PROJECTIONS ARE CALCULATED AS THESE CAN TAKE UP A TON OF MEMORY...
    call clear_unitvecs(x)

    if (myid==0) then
      print *, 'Min/max yn,zn values',minval(yn),maxval(yn),minval(zn),maxval(zn)
      print *, 'Min/max yi,zi values',minval(yi),maxval(yi),minval(zi),maxval(zi)
      print *, 'Source lat/long:  ',meanlat,meanlong
      print *, 'Plasma grid lat range:  ',minval(x%glat(:,:,:)),maxval(x%glat(:,:,:))
      print *, 'Plasma grid lon range:  ',minval(x%glon(:,:,:)),maxval(x%glon(:,:,:))
    end if
  end if


  !ALL THE NECESSARY ARRAYS EXIST AT THIS POINT, SO GO AHEAD AND READ IN THE DATA - only root should do this and then distribute to the workers
  if (myid==0) then    !root
    !read in the data from file
    print *, 'tprev,tnow,tnext:  ',tprev,t+dt/2d0,tnext
    ymdtmp=ymdnext
    UTsectmp=UTsecnext
    call dateinc(dtneu,ymdtmp,UTsectmp)    !get the date for "next" params
    filename=date_filename(neudir,ymdtmp,UTsectmp)     !form the standard data filename
    print *, 'Pulling neutral data from file:  ',trim(adjustl(filename))
    open(inunit,file=trim(adjustl(filename)),status='old',form='unformatted',access='stream')
    read(inunit) dnO,dnN2,dnO2,dvnrho,dvnz,dTn    !vnrho here interpreted as vny (yes, I'm lazy)
    close(inunit)

    print *, 'Min/max values for dnO:  ',minval(dnO),maxval(dnO)
    print *, 'Min/max values for dnN:  ',minval(dnN2),maxval(dnN2)
    print *, 'Min/max values for dnO:  ',minval(dnO2),maxval(dnO2)
    print *, 'Min/max values for dvny:  ',minval(dvnrho),maxval(dvnrho)
    print *, 'Min/max values for dvnz:  ',minval(dvnz),maxval(dvnz)
    print *, 'Min/max values for dTn:  ',minval(dTn),maxval(dTn)

    !send a full copy of the data to all of the workers
    do iid=1,lid-1
      call mpi_send(dnO,lyn*lzn,mpi_realprec,iid,tagdnO,MPI_COMM_WORLD,ierr)
      call mpi_send(dnN2,lyn*lzn,mpi_realprec,iid,tagdnN2,MPI_COMM_WORLD,ierr)
      call mpi_send(dnO2,lyn*lzn,mpi_realprec,iid,tagdnO2,MPI_COMM_WORLD,ierr)
      call mpi_send(dTn,lyn*lzn,mpi_realprec,iid,tagdTn,MPI_COMM_WORLD,ierr)
      call mpi_send(dvnrho,lyn*lzn,mpi_realprec,iid,tagdvnrho,MPI_COMM_WORLD,ierr)
      call mpi_send(dvnz,lyn*lzn,mpi_realprec,iid,tagdvnz,MPI_COMM_WORLD,ierr)
    end do
  else     !workers
    !receive a full copy of the data from root
    call mpi_recv(dnO,lyn*lzn,mpi_realprec,0,tagdnO,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dnN2,lyn*lzn,mpi_realprec,0,tagdnN2,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dnO2,lyn*lzn,mpi_realprec,0,tagdnO2,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dTn,lyn*lzn,mpi_realprec,0,tagdTn,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dvnrho,lyn*lzn,mpi_realprec,0,tagdvnrho,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
    call mpi_recv(dvnz,lyn*lzn,mpi_realprec,0,tagdvnz,MPI_COMM_WORLD,MPI_STATUS_IGNORE,ierr)
  end if


  !DO SPATIAL INTERPOLATION OF EACH PARAMETER (COULD CONSERVE SOME MEMORY BY NOT STORING DVNRHOIPREV AND DVNRHOINEXT, ETC.)
  if (myid==0) then
    print *, 'Initiating spatial interpolations for date:  ',ymdtmp,' ',UTsectmp
  end if
  parami=interp2(zn,yn,dnO,zi,yi)     !interp to temp var.
  dnOiprev=dnOinext                       !save new pervious
  dnOinext=reshape(parami,[lx1,lx2,lx3])    !overwrite next with new interpolated input

  parami=interp2(zn,yn,dnN2,zi,yi)
  dnN2iprev=dnN2inext
  dnN2inext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,yn,dnN2,zi,yi)
  dnO2iprev=dnO2inext
  dnO2inext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,yn,dvnrho,zi,yi)
  dvnrhoiprev=dvnrhoinext    !interpreted as y-component in this (cartesian) function
  dvnrhoinext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,yn,dvnz,zi,yi)
  dvnziprev=dvnzinext
  dvnzinext=reshape(parami,[lx1,lx2,lx3])

  parami=interp2(zn,yn,dTn,zi,yi)
  dTniprev=dTninext
  dTninext=reshape(parami,[lx1,lx2,lx3])


  !MORE DIAG
  if (myid==lid/2) then
    print *, 'Min/max values for dnOi:  ',minval(dnOinext),maxval(dnOinext)
    print *, 'Min/max values for dnN2i:  ',minval(dnN2inext),maxval(dnN2inext)
    print *, 'Min/max values for dnO2i:  ',minval(dnO2inext),maxval(dnO2inext)
    print *, 'Min/max values for dvyi:  ',minval(dvnrhoinext),maxval(dvnrhoinext)
    print *, 'Min/max values for dvnzi:  ',minval(dvnzinext),maxval(dvnzinext)
    print *, 'Min/max values for dTni:  ',minval(dTninext),maxval(dTninext)
  end if


  !ROTATE VECTORS INTO X1 X2 DIRECTIONS (Need to include unit vectors with grid structure)
  if (myid==0) then
    print *, 'Rotating vectors for date:  ',ymdtmp,' ',UTsectmp
  end if

  dvn1iprev=dvn1inext   !save the old data
  dvn1inext=dvnrhoinext*proj_eyp_e1+dvnzinext*proj_ezp_e1    !apply projection to complete rotation into dipole coordinates; drhoi interpreted here at teh y component (northward)

  dvn2iprev=dvn2inext
  dvn2inext=dvnrhoinext*proj_eyp_e2+dvnzinext*proj_ezp_e2

  dvn3iprev=dvn3inext
  dvn3inext=dvnrhoinext*proj_eyp_e3+dvnzinext*proj_ezp_e3


  !MORE DIAGNOSTICS
  if (myid==lid/2) then
    print *, 'Min/max values for dnOi:  ',minval(dnOinext),maxval(dnOinext)
    print *, 'Min/max values for dnN2i:  ',minval(dnN2inext),maxval(dnN2inext)
    print *, 'Min/max values for dnO2i:  ',minval(dnO2inext),maxval(dnO2inext)
    print *, 'Min/max values for dvn1i:  ',minval(dvn1inext),maxval(dvn1inext)
    print *, 'Min/max values for dvn2i:  ',minval(dvn2inext),maxval(dvn2inext)
    print *, 'Min/max values for dvn3i:  ',minval(dvn3inext),maxval(dvn3inext)
    print *, 'Min/max values for dTni:  ',minval(dTninext),maxval(dTninext)
  end if


  !UPDATE OUR CONCEPT OF PREVIOUS AND NEXT TIMES
  tprev=tnext
  UTsecprev=UTsecnext
  ymdprev=ymdnext

  tnext=tprev+dtneu
  UTsecnext=UTsectmp
  ymdnext=ymdtmp
end if


!(NOW) DO LINEAR INTERPOLATION IN TIME
do ix3=1,lx3
  do ix2=1,lx2
    do ix1=1,lx1
      slope=(dnOinext(ix1,ix2,ix3)-dnOiprev(ix1,ix2,ix3))/(tnext-tprev)
      dnOinow(ix1,ix2,ix3)=dnOiprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dnN2inext(ix1,ix2,ix3)-dnN2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dnN2inow(ix1,ix2,ix3)=dnN2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dnO2inext(ix1,ix2,ix3)-dnO2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dnO2inow(ix1,ix2,ix3)=dnO2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn1inext(ix1,ix2,ix3)-dvn1iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn1inow(ix1,ix2,ix3)=dvn1iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn2inext(ix1,ix2,ix3)-dvn2iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn2inow(ix1,ix2,ix3)=dvn2iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dvn3inext(ix1,ix2,ix3)-dvn3iprev(ix1,ix2,ix3))/(tnext-tprev)
      dvn3inow(ix1,ix2,ix3)=dvn3iprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev)

      slope=(dTninext(ix1,ix2,ix3)-dTniprev(ix1,ix2,ix3))/(tnext-tprev)
      dTninow(ix1,ix2,ix3)=dTniprev(ix1,ix2,ix3)+slope*(t+dt/2d0-tprev) 
    end do
  end do
end do


!SOME BASIC DIAGNOSTICS
if (myid==lid/2) then
  print *, myid
  print *, 'tprev,t,tnext:  ',tprev,t+dt/2d0,tnext
  print *, 'Min/max values for dnOinow:  ',minval(dnOinow),maxval(dnOinow)
  print *, 'Min/max values for dnN2inow:  ',minval(dnN2inow),maxval(dnN2inow)
  print *, 'Min/max values for dnO2inow:  ',minval(dnO2inow),maxval(dnO2inow)
  print *, 'Min/max values for dvn1inow:  ',minval(dvn1inow),maxval(dvn1inow)
  print *, 'Min/max values for dvn2inow:  ',minval(dvn2inow),maxval(dvn2inow)
  print *, 'Min/max values for dvn3inow:  ',minval(dvn3inow),maxval(dvn3inow)
  print *, 'Min/max values for dTninow:  ',minval(dTninow),maxval(dTninow)
end if


!NOW UPDATE THE PROVIDED NEUTRAL ARRAYS
nn(:,:,:,1)=nnmsis(:,:,:,1)+dnOinow
nn(:,:,:,2)=nnmsis(:,:,:,2)+dnN2inow
nn(:,:,:,3)=nnmsis(:,:,:,3)+dnO2inow 
nn(:,:,:,1)=max(nn(:,:,:,1),1._wp)
nn(:,:,:,2)=max(nn(:,:,:,2),1._wp)
nn(:,:,:,3)=max(nn(:,:,:,3),1._wp)
Tn=Tnmsis+dTninow
Tn=max(Tn,50._wp)
vn1=vn1base+dvn1inow
vn2=vn2base+dvn2inow
vn3=vn3base+dvn3inow

end subroutine neutral_perturb_cart


subroutine make_dneu()

!allocate and compute plasma grid z,rho locations and space to save neutral perturbation variables and projection factors
allocate(zi(lx1*lx2*lx3),rhoi(lx1*lx2*lx3))
allocate(yi(lx1*lx2*lx3))
allocate(proj_erhop_e1(lx1,lx2,lx3),proj_ezp_e1(lx1,lx2,lx3),proj_erhop_e2(lx1,lx2,lx3),proj_ezp_e2(lx1,lx2,lx3), &
         proj_erhop_e3(lx1,lx2,lx3),proj_ezp_e3(lx1,lx2,lx3))
allocate(proj_eyp_e1(lx1,lx2,lx3),proj_eyp_e2(lx1,lx2,lx3),proj_eyp_e3(lx1,lx2,lx3))
allocate(dnOiprev(lx1,lx2,lx3),dnN2iprev(lx1,lx2,lx3),dnO2iprev(lx1,lx2,lx3),dvnrhoiprev(lx1,lx2,lx3), &
         dvnziprev(lx1,lx2,lx3),dTniprev(lx1,lx2,lx3),dvn1iprev(lx1,lx2,lx3),dvn2iprev(lx1,lx2,lx3), &
         dvn3iprev(lx1,lx2,lx3))
allocate(dnOinext(lx1,lx2,lx3),dnN2inext(lx1,lx2,lx3),dnO2inext(lx1,lx2,lx3),dvnrhoinext(lx1,lx2,lx3), &
         dvnzinext(lx1,lx2,lx3),dTninext(lx1,lx2,lx3),dvn1inext(lx1,lx2,lx3),dvn2inext(lx1,lx2,lx3), &
         dvn3inext(lx1,lx2,lx3))
allocate(nnmsis(lx1,lx2,lx3,lnchem),Tnmsis(lx1,lx2,lx3),vn1base(lx1,lx2,lx3),vn2base(lx1,lx2,lx3),vn3base(lx1,lx2,lx3))

!start everyone out at zero
zi=0d0; rhoi=0d0; yi=0d0;
proj_erhop_e1=0d0; proj_ezp_e1=0d0;
proj_erhop_e2=0d0; proj_ezp_e2=0d0;
proj_erhop_e3=0d0; proj_ezp_e3=0d0;
proj_eyp_e1=0d0; proj_eyp_e2=0d0; proj_eyp_e3=0d0;
dnOiprev=0d0; dnN2iprev=0d0; dnO2iprev=0d0; dTniprev=0d0; dvnrhoiprev=0d0; dvnziprev=0d0;
dvn1iprev=0d0; dvn2iprev=0d0; dvn3iprev=0d0;
dnOinext=0d0; dnN2inext=0d0; dnO2inext=0d0; dTninext=0d0; dvnrhoinext=0d0; dvnzinext=0d0;
dvn1inext=0d0; dvn2inext=0d0; dvn3inext=0d0;
nnmsis=0d0; Tnmsis=0d0; vn1base=0d0; vn2base=0d0; vn3base=0d0

!now initialize some module variables
tprev=0d0; tnext=0d0

end subroutine make_dneu


subroutine clear_dneu

!stuff allocated at beginning of program
deallocate(zi,rhoi)
deallocate(yi)
deallocate(proj_erhop_e1,proj_ezp_e1,proj_erhop_e2,proj_ezp_e2, &
         proj_erhop_e3,proj_ezp_e3)
deallocate(proj_eyp_e1,proj_eyp_e2,proj_eyp_e3)
deallocate(dnOiprev,dnN2iprev,dnO2iprev,dvnrhoiprev,dvnziprev,dTniprev,dvn1iprev,dvn2iprev,dvn3iprev)
deallocate(dnOinext,dnN2inext,dnO2inext,dvnrhoinext,dvnzinext,dTninext,dvn1inext,dvn2inext,dvn3inext)
deallocate(nnmsis,Tnmsis,vn1base,vn2base,vn3base)

!check whether any other module variables were allocated and deallocate accordingly
if (allocated(zn) ) then    !if one is allocated, then they all are
  deallocate(rhon,zn)
  deallocate(yn)
  deallocate(dnO,dnN2,dnO2,dvnrho,dvnz,dTn)
end if

end subroutine clear_dneu

end module neutral

