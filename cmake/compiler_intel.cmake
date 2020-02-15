if(WIN32)
  set(CMAKE_Fortran_FLAGS /warn:declarations /traceback)
  list(APPEND CMAKE_Fortran_FLAGS /Qopenmp)
  list(APPEND CMAKE_Fortran_FLAGS /heap-arrays)  # necessary for stack overflow avoid
else()
  set(CMAKE_Fortran_FLAGS "-warn declarations -traceback ")  # -warn all or -warn gets mixed with -qopenmp with CMake 3.14.2
  string(APPEND CMAKE_Fortran_FLAGS "-qopenmp ")  # undefined reference to `omp_get_max_threads'
  string(APPEND CMAKE_Fortran_FLAGS "-heap-arrays ")  # (is this needed on Linux?) stack overflow avoid
endif(WIN32)

if(WIN32)
  #add_link_options(/Qparallel)
else()
  add_link_options(-parallel) # undefined reference to `__kmpc_begin'
endif(WIN32)

if(CMAKE_BUILD_TYPE STREQUAL Debug)
  if(WIN32)
    list(APPEND CMAKE_Fortran_FLAGS /check:bounds)
  else()
    #string(APPEND CMAKE_Fortran_FLAGS "-check all")
    #string(APPEND CMAKE_Fortran_FLAGS "-debug extended" "-check all" -fpe0 -fp-stack-check)
    string(APPEND CMAKE_Fortran_FLAGS "-check bounds ")
  endif()
endif()

# reduce build-time warning verbosity
if(WIN32)
  list(APPEND CMAKE_Fortran_FLAGS /warn:nounused /Qdiag-disable:5268 /Qdiag-disable:7712)
else()
  string(APPEND CMAKE_Fortran_FLAGS "-warn nounused -diag-disable 5268 -diag-disable 7712 ")
endif(WIN32)

# enforce Fortran 2018 standard
if (CMAKE_Fortran_COMPILER_VERSION VERSION_GREATER_EQUAL 19)
  if(WIN32)
    list(APPEND CMAKE_Fortran_FLAGS /stand:f18)
  else()
    string(APPEND CMAKE_Fortran_FLAGS "-stand f18 ")
  endif()
endif()
