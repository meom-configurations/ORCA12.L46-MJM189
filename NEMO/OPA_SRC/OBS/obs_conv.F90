MODULE obs_conv
   !!=====================================================================
   !!                       ***  MODULE  obs_conv  ***
   !! Observation diagnostics: Various conversion functions
   !!=====================================================================
   !!
   !!   potemp   : Compute potential temperature from insitu temperature,
   !!              salinity and pressure
   !!   fspott   : Compute potential temperature from insitu temperature,
   !!              salinity and pressure
   !!   atg      : Compute adiabatic temperature gradient deg c per decibar
   !!   theta    : Compute potential temperature from insitu temperature,
   !!              salinity and pressure
   !!   depth    : Compute depth from pressure and latitude.
   !!   p_to_dep : Compute depth from pressure and latitude 
   !!              (approximate version)
   !!   dep_to_p : Compute pressure from depth and latitude 
   !!              (approximate version)
   !!---------------------------------------------------------------------
   !! * Modules used
   USE par_kind, ONLY : & ! Precision variables
      & wp   
   IMPLICIT NONE
 
   !! * Function accessibility
   PRIVATE
   PUBLIC &
      & potemp,   &
      & fspott,   &
      & atg,      &
      & theta,    &
      & depth,    &
      & p_to_dep, &
      & dep_to_p
   
   !!----------------------------------------------------------------------
   !! NEMO/OPA 3.3 , NEMO Consortium (2010)
   !! $Id: obs_conv.F90 2287 2010-10-18 07:53:52Z smasson $
   !! Software governed by the CeCILL licence (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------

CONTAINS

#include "obs_conv_functions.h90"

END MODULE obs_conv
