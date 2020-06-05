submodule (io) output

use, intrinsic :: iso_fortran_env, only: compiler_version, compiler_options, real32, real64

implicit none (type, external)

contains


module procedure create_outdir
!! CREATES OUTPUT DIRECTORY, MOVES CONFIG FILES THERE AND GENERATES A GRID OUTPUT FILE

integer :: ierr, u, realbits
logical :: porcelain, exists
character(:), allocatable :: input_nml, output_dir, branch, rev, compiler, compiler_flags, exe
character(256) :: buf
integer :: mcadence

namelist /files/ input_nml, output_dir,realbits
namelist /git/ branch, rev, porcelain
namelist /system/ compiler, compiler_flags, exe
namelist /milestone/ mcadence

!> MAKE A COPY OF THE INPUT DATA IN THE OUTPUT DIRECTORY
ierr = mkdir(cfg%outdir//'/inputs')

inquire(file=cfg%outdir//'/inputs/config.nml', exist=exists)
if(.not.exists) then
  ierr = copyfile(cfg%infile, cfg%outdir//'/inputs/')
  ierr = copyfile(cfg%indatsize, cfg%outdir//'/inputs/')
  ierr = copyfile(cfg%indatgrid, cfg%outdir//'/inputs/')
  ierr = copyfile(cfg%indatfile, cfg%outdir//'/inputs/')
endif
!! keep these copyfile() to allow running Gemini from command-line without Python / Matlab scripts

!> NOTE: if desired to copy Efield inputs. This would be a lot of files and disk space in general.
! if(cfg%flagE0file == 1) then
!   inquire(file=cfg%E0dir//'/simgrid.h5', exist=exists)
!   if(.not.exists) then
!
!   endif
! endif


call gitlog(cfg%outdir // '/gitrev.log')

!> Log to output.nml

!> files namelist
input_nml = cfg%infile
output_dir = cfg%outdir
!! character namelist variables can't be assumed length, but can be allocatable.

select case (wp)
case (real64)
  realbits = 64
case (real32)
  realbits = 32
case default
  error stop 'unknown real precision'
end select

!> git namelist
branch = ''
rev = ''
porcelain = .false.
open(newunit=u, file=cfg%outdir// '/gitrev.log', status='old', action='read', iostat=ierr)
if(ierr==0) then
  read(u, '(A256)', iostat=ierr) buf
  if(ierr==0) branch = trim(buf)
  read(u, '(A256)', iostat=ierr) buf
  if(ierr==0) rev = trim(buf)
  read(u, '(A256)', iostat=ierr) buf
  if (len_trim(buf)==0 .or. is_iostat_end(ierr)) porcelain=.true.
  close(u)
endif

!> system namelist
compiler = trim(compiler_version())
compiler_flags = trim(compiler_options())
call get_command_argument(0, buf)
exe = trim(buf)

!> milestone namelist
mcadence=cfg%mcadence

!> let this crash the program if it can't write as an early indicator of output directory problem.
open(newunit=u, file=cfg%outdir // '/output.nml', status='unknown', action='write')
  write(u, nml=files)
  write(u, nml=git)
  write(u, nml=system)
  write(u, nml=milestone)
close(u)

end procedure create_outdir


subroutine gitlog(logpath)
!! logs git branch, hash to file

character(*), intent(in) :: logpath
integer :: ierr

!> git branch --show-current requires Git >= 2.22, June 2019
call execute_command_line('git rev-parse --abbrev-ref HEAD > '// logpath, cmdstat=ierr)
if(ierr /= 0) then
  write(stderr, *) 'ERROR: failed to log Git branch'
  return
endif

!> write hash
call execute_command_line('git rev-parse --short HEAD >> '// logpath, cmdstat=ierr)
if(ierr /= 0) then
  write(stderr, *) 'ERROR: failed to log Git hash'
  return
endif

!> write changed filenames
call execute_command_line('git status --porcelain >> '// logpath, cmdstat=ierr)
if(ierr /= 0) then
  write(stderr, *) 'ERROR: failed to log Git filenames'
  return
endif

end subroutine gitlog


subroutine compiler_log(logpath)

character(*), intent(in) :: logpath
integer :: u, ierr

open(newunit=u, file=logpath, status='unknown', action='write', iostat=ierr)
if(ierr /= 0) return

write(u,'(A,/,A)') compiler_version(), compiler_options()

close(u)

end subroutine compiler_log


end submodule output
