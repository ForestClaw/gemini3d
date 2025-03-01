include(CheckSymbolExists)
include(CheckIncludeFile)

if(BUILD_TESTING)
  add_executable(echo_path echo_path.f90)
  add_test(NAME debug:EchoEnvVar COMMAND $<TARGET_FILE:echo_path>)
endif()

#--------magnetic field calculation executable---------------
configure_file(magcalc_cli.in.f90 magcalc_cli.f90 @ONLY)
add_executable(magcalc.bin)
target_sources(magcalc.bin PRIVATE magcalc.f90 ${CMAKE_CURRENT_BINARY_DIR}/magcalc_cli.f90
  $<TARGET_OBJECTS:autogrid> $<TARGET_OBJECTS:grid>
  $<TARGET_OBJECTS:mpimod>
  $<TARGET_OBJECTS:meshobj> $<TARGET_OBJECTS:meshobj_cart> $<TARGET_OBJECTS:meshobj_dipole> $<TARGET_OBJECTS:spherical> $<TARGET_OBJECTS:newton> $<TARGET_OBJECTS:geomagnetic>
  $<TARGET_OBJECTS:reader> $<TARGET_OBJECTS:io>
)
target_link_libraries(magcalc.bin PRIVATE exe_frontend
  pathlib sanity_check errors config timeutils const hwloc_ifc hwloc_c nc4fortran::nc4fortran h5fortran::h5fortran)
target_link_libraries(magcalc.bin PRIVATE MPI::MPI_Fortran)
if(NOT mpi)
  target_link_libraries(magcalc.bin PRIVATE MUMPS::MPISEQ)
endif()
set_target_properties(magcalc.bin PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})

add_test(NAME unit:magcalc_exe_ok COMMAND $<TARGET_FILE:magcalc.bin>)
set_tests_properties(unit:magcalc_exe_ok PROPERTIES
  PASS_REGULAR_EXPRESSION "EOF: magcalc.bin"
  LABELS unit
  TIMEOUT 10)

# --- gemini3d.run Fortran front end
add_subdirectory(hwloc)

configure_file(exe_frontend.in.f90 exe_frontend.f90 @ONLY)

add_library(exe_frontend OBJECT ${CMAKE_CURRENT_BINARY_DIR}/exe_frontend.f90)
target_link_libraries(exe_frontend PRIVATE config hwloc_ifc hwloc_c pathlib)

# --- gemini3d.run
add_executable(gemini3d.run gemini3d_run.f90 runner.f90 $<TARGET_OBJECTS:exe_frontend>)
target_link_libraries(gemini3d.run PRIVATE const config timeutils autogrid reader pathlib
  h5fortran::h5fortran nc4fortran::nc4fortran hwloc_ifc hwloc_c)
if(HWLOC_FOUND)
  target_link_libraries(gemini3d.run PRIVATE HWLOC::HWLOC)
endif()
if(HDF5_HAVE_PARALLEL)
  target_link_libraries(gemini3d.run PRIVATE MPI::MPI_Fortran)
endif()
set_target_properties(gemini3d.run PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})

add_test(NAME unit:gemini3d_run_ok COMMAND $<TARGET_FILE:gemini3d.run>)
set_tests_properties(unit:gemini3d_run_ok PROPERTIES
  PASS_REGULAR_EXPRESSION "EOF: gemini3d.run"
  DEPENDS unit:HWLOC
  LABELS unit
  TIMEOUT 10)

# --- magcalc.run

add_executable(magcalc.run magcalc_run.f90)
target_link_libraries(magcalc.run PRIVATE exe_frontend autogrid reader config pathlib const hwloc_ifc hwloc_c
  h5fortran::h5fortran nc4fortran::nc4fortran)
if(HWLOC_FOUND)
  target_link_libraries(magcalc.run PRIVATE HWLOC::HWLOC)
endif()
if(HDF5_HAVE_PARALLEL)
  target_link_libraries(magcalc.run PRIVATE MPI::MPI_Fortran)
endif()
set_target_properties(magcalc.run PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})

add_test(NAME unit:magcalc_run_ok COMMAND $<TARGET_FILE:magcalc.run>)
set_tests_properties(unit:magcalc_run_ok PROPERTIES
  PASS_REGULAR_EXPRESSION "EOF: magcalc.run"
  DEPENDS unit:HWLOC
  LABELS unit
  TIMEOUT 10)

if(test_dll_path)
  set_tests_properties(unit:magcalc_exe_ok unit:magcalc_run_ok unit:gemini3d_run_ok PROPERTIES
    ENVIRONMENT "PATH=${test_dll_path}")
endif()

# --- Gemini compare

add_library(assert OBJECT assert.f90)

add_executable(gemini3d.compare)
target_sources(gemini3d.compare PRIVATE
  gemini_compare.f90
  ${CMAKE_CURRENT_SOURCE_DIR}/../io/compare.f90
  ${CMAKE_CURRENT_SOURCE_DIR}/../io/compare_grid_h5.f90
  ${CMAKE_CURRENT_SOURCE_DIR}/../io/compare_out_h5.f90
  ${CMAKE_CURRENT_SOURCE_DIR}/../io/compare_in_h5.f90)
target_link_libraries(gemini3d.compare PRIVATE assert config reader pathlib timeutils const
  nc4fortran::nc4fortran h5fortran::h5fortran)
if(HDF5_HAVE_PARALLEL)
  target_link_libraries(gemini3d.compare PRIVATE MPI::MPI_Fortran)
endif()

set_target_properties(gemini3d.compare PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR})


install(TARGETS magcalc.bin gemini3d.run magcalc.run gemini3d.compare
  EXPORT ${PROJECT_NAME}Targets)
