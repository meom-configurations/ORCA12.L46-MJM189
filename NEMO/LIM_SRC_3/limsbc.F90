MODULE limsbc
   !!======================================================================
   !!                       ***  MODULE limsbc   ***
   !!           computation of the flux at the sea ice/ocean interface
   !!======================================================================
   !! History :   -   ! 2006-07 (M. Vancoppelle)  LIM3 original code
   !!            3.0  ! 2008-03 (C. Tallandier)  surface module
   !!             -   ! 2008-04 (C. Tallandier)  split in 2 + new ice-ocean coupling
   !!            3.3  ! 2010-05 (G. Madec) decrease ocean & ice reference salinities in the Baltic sea
   !!                 !                  + simplification of the ice-ocean stress calculation
   !!            3.4  ! 2011-02 (G. Madec) dynamical allocation
   !!            3.5  ! 2012-10 (A. Coward, G. Madec) salt fluxes ; ice+snow mass
   !!----------------------------------------------------------------------
#if defined key_lim3
   !!----------------------------------------------------------------------
   !!   'key_lim3'                                    LIM 3.0 sea-ice model
   !!----------------------------------------------------------------------
   !!   lim_sbc_alloc : allocate the limsbc arrays
   !!   lim_sbc_init  : initialisation
   !!   lim_sbc_flx   : updates mass, heat and salt fluxes at the ocean surface
   !!   lim_sbc_tau   : update i- and j-stresses, and its modulus at the ocean surface
   !!----------------------------------------------------------------------
   USE par_oce          ! ocean parameters
   USE par_ice          ! ice parameters
   USE dom_oce          ! ocean domain
   USE sbc_ice          ! Surface boundary condition: sea-ice fields
   USE sbc_oce          ! Surface boundary condition: ocean fields
   USE phycst           ! physical constants
   USE albedo           ! albedo parameters
   USE ice              ! LIM sea-ice variables
   USE lbclnk           ! ocean lateral boundary condition
   USE in_out_manager   ! I/O manager
   USE lib_mpp          ! MPP library
   USE wrk_nemo         ! work arrays
   USE prtctl           ! Print control
   USE cpl_oasis3, ONLY : lk_cpl
   USE oce,        ONLY : sshn, sshb, snwice_mass, snwice_mass_b, snwice_fmass, sshu_b, sshv_b, sshu_n, sshv_n, sshf_n
   USE dom_ice,    ONLY : tms
   USE lib_fortran      ! Fortran utilities (allows no signed zero when 'key_nosignedzero' defined)  

   IMPLICIT NONE
   PRIVATE

   PUBLIC   lim_sbc_init   ! called by ice_init
   PUBLIC   lim_sbc_flx    ! called by sbc_ice_lim
   PUBLIC   lim_sbc_tau    ! called by sbc_ice_lim

   REAL(wp)  ::   epsi16 = 1.e-16_wp   ! constant values
   REAL(wp)  ::   rzero  = 0._wp    
   REAL(wp)  ::   rone   = 1._wp

   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   utau_oce, vtau_oce   ! air-ocean surface i- & j-stress     [N/m2]
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   tmod_io              ! modulus of the ice-ocean velocity   [m/s]
   REAL(wp), ALLOCATABLE, SAVE, DIMENSION(:,:) ::   soce_0  , sice_0     ! cst SSS and ice salinity (levitating sea-ice) 

   !! * Substitutions
#  include "vectopt_loop_substitute.h90"
   !!----------------------------------------------------------------------
   !! NEMO/LIM3 3.4 , UCL - NEMO Consortium (2011)
   !! $Id: limsbc.F90 3905 2013-05-24 13:40:39Z cetlod $
   !! Software governed by the CeCILL licence     (NEMOGCM/NEMO_CeCILL.txt)
   !!----------------------------------------------------------------------
CONTAINS

   INTEGER FUNCTION lim_sbc_alloc()
      !!-------------------------------------------------------------------
      !!             ***  ROUTINE lim_sbc_alloc ***
      !!-------------------------------------------------------------------
      ALLOCATE( soce_0(jpi,jpj) , utau_oce(jpi,jpj) ,                       &
         &      sice_0(jpi,jpj) , vtau_oce(jpi,jpj) , tmod_io(jpi,jpj), STAT=lim_sbc_alloc)
         !
      IF( lk_mpp             )   CALL mpp_sum( lim_sbc_alloc )
      IF( lim_sbc_alloc /= 0 )   CALL ctl_warn('lim_sbc_alloc: failed to allocate arrays')
   END FUNCTION lim_sbc_alloc


   SUBROUTINE lim_sbc_flx( kt )
      !!-------------------------------------------------------------------
      !!                ***  ROUTINE lim_sbc_flx ***
      !!  
      !! ** Purpose :   Update the surface ocean boundary condition for heat 
      !!              salt and mass over areas where sea-ice is non-zero
      !!         
      !! ** Action  : - computes the heat and freshwater/salt fluxes
      !!              at the ice-ocean interface.
      !!              - Update the ocean sbc
      !!     
      !! ** Outputs : - qsr     : sea heat flux:     solar 
      !!              - qns     : sea heat flux: non solar
      !!              - emp     : freshwater budget: volume flux 
      !!              - sfx     : salt flux 
      !!              - fr_i    : ice fraction
      !!              - tn_ice  : sea-ice surface temperature
      !!              - alb_ice : sea-ice alberdo (lk_cpl=T)
      !!
      !! References : Goosse, H. et al. 1996, Bul. Soc. Roy. Sc. Liege, 65, 87-90.
      !!              Tartinville et al. 2001 Ocean Modelling, 3, 95-108.
      !!---------------------------------------------------------------------
      INTEGER, INTENT(in) ::   kt    ! number of iteration
      !
      INTEGER  ::   ji, jj           ! dummy loop indices
      INTEGER  ::   ierr, ifvt, i1mfr, idfr           ! local integer
      INTEGER  ::   iflt, ial , iadv , ifral, ifrdv   !   -      -
      REAL(wp) ::   zinda, zemp, zemp_snow, zfmm      ! local scalars
      REAL(wp) ::   zemp_snw                          !   -      -
      REAL(wp) ::   zfcm1 , zfcm2                     !   -      -
      REAL(wp), POINTER, DIMENSION(:,:,:) ::   zalb, zalbp     ! 2D/3D workspace
      !!---------------------------------------------------------------------
      
      IF( lk_cpl )   CALL wrk_alloc( jpi, jpj, jpl, zalb, zalbp )

      !------------------------------------------!
      !      heat flux at the ocean surface      !
      !------------------------------------------!
      ! pfrld is the lead fraction at the previous time step (actually between TRP and THD)
      ! changed to old_frld and old ht_i

      DO jj = 1, jpj
         DO ji = 1, jpi
            zinda   = 1.0 - MAX( rzero , SIGN( rone , - ( 1.0 - pfrld(ji,jj) ) ) )
            ifvt    = zinda  *  MAX( rzero , SIGN( rone, -phicif  (ji,jj) ) )  !subscripts are bad here
            i1mfr   = 1.0 - MAX( rzero , SIGN( rone ,  - ( at_i(ji,jj)       ) ) )
            idfr    = 1.0 - MAX( rzero , SIGN( rone , ( 1.0 - at_i(ji,jj) ) - pfrld(ji,jj) ) )
            iflt    = zinda  * (1 - i1mfr) * (1 - ifvt )
            ial     = ifvt   * i1mfr + ( 1 - ifvt ) * idfr
            iadv    = ( 1  - i1mfr ) * zinda
            ifral   = ( 1  - i1mfr * ( 1 - ial ) )   
            ifrdv   = ( 1  - ifral * ( 1 - ial ) ) * iadv 

            ! switch --- 1.0 ---------------- 0.0 --------------------
            ! ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            ! zinda   | if pfrld = 1       | if pfrld < 1            |
            !  -> ifvt| if pfrld old_ht_i
            ! i1mfr   | if frld = 1        | if frld  < 1            |
            ! idfr    | if frld <= pfrld    | if frld > pfrld        |
            ! iflt    | 
            ! ial     |
            ! iadv    |
            ! ifral
            ! ifrdv

            !   computation the solar flux at ocean surface
            zfcm1   = pfrld(ji,jj) * qsr(ji,jj)  + ( 1._wp - pfrld(ji,jj) ) * fstric(ji,jj)
            ! fstric     Solar flux transmitted trough the ice
            ! qsr        Net short wave heat flux on free ocean
            ! new line
            fscmbq(ji,jj) = ( 1.0 - pfrld(ji,jj) ) * fstric(ji,jj)

            !  computation the non solar heat flux at ocean surface
            zfcm2 = - zfcm1                                                                     & ! ???
               &    + iflt    * fscmbq(ji,jj)                                                   & ! total ablation: heat given to the ocean
               &    + ifral   * ( ial * qcmif(ji,jj) + (1 - ial) * qldif(ji,jj) ) * r1_rdtice   &
               &    + ifrdv   * (       qfvbq(ji,jj) +             qdtcn(ji,jj) ) * r1_rdtice   &
               &    + fhmec(ji,jj)                                                              & ! snow melt when ridging
               &    + fheat_mec(ji,jj)                                                          & ! ridge formation
               &    + fheat_res(ji,jj)                                                            ! residual heat flux
            ! qcmif   Energy needed to bring the ocean surface layer until its freezing (ok)
            ! qldif   heat balance of the lead (or of the open ocean)
            ! qfvbq   latent heat uptake/release after accretion/ablation
            ! qdtcn   Energy from the turbulent oceanic heat flux heat flux coming in the lead

            IF( num_sal == 2 )   zfcm2 = zfcm2 + fhbri(ji,jj)    ! add contribution due to brine drainage 

            ! bottom radiative component is sent to the computation of the oceanic heat flux
            fsbbq(ji,jj) = ( 1._wp - ( ifvt + iflt ) ) * fscmbq(ji,jj)     

            ! used to compute the oceanic heat flux at the next time step
            qsr(ji,jj) = zfcm1                                       ! solar heat flux 
            qns(ji,jj) = zfcm2 - fdtcn(ji,jj)                        ! non solar heat flux
            !                           ! fdtcn : turbulent oceanic heat flux

!!gm   this IF prevents the vertorisation of the whole loop
            IF ( ( ji == jiindx ) .AND. ( jj == jjindx) ) THEN
               WRITE(numout,*) ' lim_sbc : heat fluxes '
               WRITE(numout,*) ' qsr       : ', qsr(jiindx,jjindx)
               WRITE(numout,*) ' pfrld     : ', pfrld(jiindx,jjindx)
               WRITE(numout,*) ' fstric    : ', fstric (jiindx,jjindx)
               WRITE(numout,*)
               WRITE(numout,*) ' qns       : ', qns(jiindx,jjindx)
               WRITE(numout,*) ' fdtcn     : ', fdtcn(jiindx,jjindx)
               WRITE(numout,*) ' ifral     : ', ifral
               WRITE(numout,*) ' ial       : ', ial  
               WRITE(numout,*) ' qcmif     : ', qcmif(jiindx,jjindx)
               WRITE(numout,*) ' qldif     : ', qldif(jiindx,jjindx)
               WRITE(numout,*) ' qcmif / dt: ', qcmif(jiindx,jjindx) * r1_rdtice
               WRITE(numout,*) ' qldif / dt: ', qldif(jiindx,jjindx) * r1_rdtice
               WRITE(numout,*) ' ifrdv     : ', ifrdv
               WRITE(numout,*) ' qfvbq     : ', qfvbq(jiindx,jjindx)
               WRITE(numout,*) ' qdtcn     : ', qdtcn(jiindx,jjindx)
               WRITE(numout,*) ' qfvbq / dt: ', qfvbq(jiindx,jjindx) * r1_rdtice
               WRITE(numout,*) ' qdtcn / dt: ', qdtcn(jiindx,jjindx) * r1_rdtice
               WRITE(numout,*) ' '
               WRITE(numout,*) ' fdtcn     : ', fdtcn(jiindx,jjindx)
               WRITE(numout,*) ' fhmec     : ', fhmec(jiindx,jjindx)
               WRITE(numout,*) ' fheat_mec : ', fheat_mec(jiindx,jjindx)
               WRITE(numout,*) ' fhbri     : ', fhbri(jiindx,jjindx)
               WRITE(numout,*) ' fheat_res : ', fheat_res(jiindx,jjindx)
            ENDIF
!!gm   end
         END DO
      END DO

      !------------------------------------------!
      !      mass flux at the ocean surface      !
      !------------------------------------------!

!!gm   optimisation: this loop have to be merged with the previous one
      DO jj = 1, jpj
         DO ji = 1, jpi
            !  case of realistic freshwater flux (Tartinville et al., 2001) (presently ACTIVATED)
            !  ------------------------------------------------------------------------------------- 
            !  The idea of this approach is that the system that we consider is the ICE-OCEAN system
            !  Thus  FW  flux  =  External ( E-P+snow melt)
            !       Salt flux  =  Exchanges in the ice-ocean system then converted into FW
            !                     Associated to Ice formation AND Ice melting
            !                     Even if i see Ice melting as a FW and SALT flux
            !        

            !  computing freshwater exchanges at the ice/ocean interface
            zemp =   emp(ji,jj)     * ( 1.0 - at_i(ji,jj)          )  &   ! evaporation over oceanic fraction
               &   - tprecip(ji,jj) *         at_i(ji,jj)             &   ! all precipitation reach the ocean
               &   + sprecip(ji,jj) * ( 1. - (pfrld(ji,jj)**betas) )  &   ! except solid precip intercepted by sea-ice
               &   - fmmec(ji,jj)                                         ! snow falling when ridging

            ! mass flux at the ocean/ice interface (sea ice fraction)
            zemp_snw = rdm_snw(ji,jj) * r1_rdtice                         ! snow melting = pure water that enters the ocean
            zfmm     = rdm_ice(ji,jj) * r1_rdtice                         ! Freezing minus mesting  

            fmmflx(ji,jj) = zfmm                                     ! F/M mass flux save at least for biogeochemical model

            emp(ji,jj) = zemp + zemp_snw + zfmm  ! mass flux + F/M mass flux (always ice/ocean mass exchange)
            
            !  correcting brine salt fluxes   (zinda = 1  if pfrld=1 , =0 otherwise)
            zinda        = 1.0 - MAX( rzero , SIGN( rone , - ( 1.0 - pfrld(ji,jj) ) ) )
            sfx_bri(ji,jj) = zinda * sfx_bri(ji,jj)
         END DO
      END DO

      !------------------------------------------!
      !      salt flux at the ocean surface      !
      !------------------------------------------!

      IF( num_sal == 2 ) THEN      ! variable ice salinity: brine drainage included in the salt flux
         sfx(:,:) = sfx_thd(:,:) + sfx_res(:,:) + sfx_mec(:,:) + sfx_bri(:,:)
      ELSE                         ! constant ice salinity:
         sfx(:,:) = sfx_thd(:,:) + sfx_res(:,:) + sfx_mec(:,:)
      ENDIF
      !-----------------------------------------------!
      !   mass of snow and ice per unit area          !
      !-----------------------------------------------!
      IF( nn_ice_embd /= 0 ) THEN                               ! embedded sea-ice (mass required)
         snwice_mass_b(:,:) = snwice_mass(:,:)                  ! save mass from the previous ice time step
         !                                                      ! new mass per unit area
         snwice_mass  (:,:) = tms(:,:) * ( rhosn * vt_s(:,:) + rhoic * vt_i(:,:)  ) 
         !                                                      ! time evolution of snow+ice mass
         snwice_fmass (:,:) = ( snwice_mass(:,:) - snwice_mass_b(:,:) ) * r1_rdtice
      ENDIF

      !-----------------------------------------------!
      !   Storing the transmitted variables           !
      !-----------------------------------------------!
      fr_i  (:,:)   = at_i(:,:)             ! Sea-ice fraction            
      tn_ice(:,:,:) = t_su(:,:,:)           ! Ice surface temperature                      

      !------------------------------------------------!
      !    Computation of snow/ice and ocean albedo    !
      !------------------------------------------------!
      IF( lk_cpl ) THEN          ! coupled case
         CALL albedo_ice( t_su, ht_i, ht_s, zalbp, zalb )                  ! snow/ice albedo
         !
         alb_ice(:,:,:) =  0.5_wp * zalbp(:,:,:) + 0.5_wp * zalb (:,:,:)   ! Ice albedo (mean clear and overcast skys)
      ENDIF

      IF(ln_ctl) THEN
         CALL prt_ctl( tab2d_1=qsr   , clinfo1=' lim_sbc: qsr    : ', tab2d_2=qns , clinfo2=' qns     : ' )
         CALL prt_ctl( tab2d_1=emp   , clinfo1=' lim_sbc: emp    : ', tab2d_2=sfx , clinfo2=' sfx     : ' )
         CALL prt_ctl( tab2d_1=fr_i  , clinfo1=' lim_sbc: fr_i   : ' )
         CALL prt_ctl( tab3d_1=tn_ice, clinfo1=' lim_sbc: tn_ice : ', kdim=jpl )
      ENDIF
      !
      IF( lk_cpl )   CALL wrk_dealloc( jpi, jpj, jpl, zalb, zalbp )
      ! 
   END SUBROUTINE lim_sbc_flx


   SUBROUTINE lim_sbc_tau( kt , pu_oce, pv_oce )
      !!-------------------------------------------------------------------
      !!                ***  ROUTINE lim_sbc_tau ***
      !!  
      !! ** Purpose : Update the ocean surface stresses due to the ice
      !!         
      !! ** Action  : * at each ice time step (every nn_fsbc time step):
      !!                - compute the modulus of ice-ocean relative velocity 
      !!                  (*rho*Cd) at T-point (C-grid) or I-point (B-grid)
      !!                      tmod_io = rhoco * | U_ice-U_oce |
      !!                - update the modulus of stress at ocean surface
      !!                      taum = frld * taum + (1-frld) * tmod_io * | U_ice-U_oce |
      !!              * at each ocean time step (every kt): 
      !!                  compute linearized ice-ocean stresses as
      !!                      Utau = tmod_io * | U_ice - pU_oce |
      !!                using instantaneous current ocean velocity (usually before)
      !!
      !!    NB: - ice-ocean rotation angle no more allowed
      !!        - here we make an approximation: taum is only computed every ice time step
      !!          This avoids mutiple average to pass from T -> U,V grids and next from U,V grids 
      !!          to T grid. taum is used in TKE and GLS, which should not be too sensitive to this approximaton...
      !!
      !! ** Outputs : - utau, vtau   : surface ocean i- and j-stress (u- & v-pts) updated with ice-ocean fluxes
      !!              - taum         : modulus of the surface ocean stress (T-point) updated with ice-ocean fluxes
      !!---------------------------------------------------------------------
      INTEGER ,                     INTENT(in) ::   kt               ! ocean time-step index
      REAL(wp), DIMENSION(jpi,jpj), INTENT(in) ::   pu_oce, pv_oce   ! surface ocean currents
      !!
      INTEGER  ::   ji, jj   ! dummy loop indices
      REAL(wp) ::   zat_u, zutau_ice, zu_t, zmodt   ! local scalar
      REAL(wp) ::   zat_v, zvtau_ice, zv_t          !   -      -
      !!---------------------------------------------------------------------
      !
      IF( MOD( kt-1, nn_fsbc ) == 0 ) THEN     !==  Ice time-step only  ==!   (i.e. surface module time-step)
!CDIR NOVERRCHK
         DO jj = 2, jpjm1                             !* update the modulus of stress at ocean surface (T-point)
!CDIR NOVERRCHK
            DO ji = fs_2, fs_jpim1
               !                                               ! 2*(U_ice-U_oce) at T-point
               zu_t = u_ice(ji,jj) + u_ice(ji-1,jj) - u_oce(ji,jj) - u_oce(ji-1,jj)   
               zv_t = v_ice(ji,jj) + v_ice(ji,jj-1) - v_oce(ji,jj) - v_oce(ji,jj-1) 
               !                                              ! |U_ice-U_oce|^2
               zmodt =  0.25_wp * (  zu_t * zu_t + zv_t * zv_t  )
               !                                               ! update the ocean stress modulus
               taum(ji,jj) = ( 1._wp - at_i(ji,jj) ) * taum(ji,jj) + at_i(ji,jj) * rhoco * zmodt
               tmod_io(ji,jj) = rhoco * SQRT( zmodt )          ! rhoco * |U_ice-U_oce| at T-point
            END DO
         END DO
         CALL lbc_lnk( taum, 'T', 1. )   ;   CALL lbc_lnk( tmod_io, 'T', 1. )
         !
         utau_oce(:,:) = utau(:,:)                    !* save the air-ocean stresses at ice time-step
         vtau_oce(:,:) = vtau(:,:)
         !
      ENDIF
      !
      !                                      !==  every ocean time-step  ==!
      !
      DO jj = 2, jpjm1                                !* update the stress WITHOUT a ice-ocean rotation angle
         DO ji = fs_2, fs_jpim1   ! Vect. Opt.
            zat_u  = ( at_i(ji,jj) + at_i(ji+1,jj) ) * 0.5_wp   ! ice area at u and V-points
            zat_v  = ( at_i(ji,jj) + at_i(ji,jj+1) ) * 0.5_wp
            !                                                   ! linearized quadratic drag formulation
            zutau_ice   = 0.5_wp * ( tmod_io(ji,jj) + tmod_io(ji+1,jj) ) * ( u_ice(ji,jj) - pu_oce(ji,jj) )
            zvtau_ice   = 0.5_wp * ( tmod_io(ji,jj) + tmod_io(ji,jj+1) ) * ( v_ice(ji,jj) - pv_oce(ji,jj) )
            !                                                   ! stresses at the ocean surface
            utau(ji,jj) = ( 1._wp - zat_u ) * utau_oce(ji,jj) + zat_u * zutau_ice
            vtau(ji,jj) = ( 1._wp - zat_v ) * vtau_oce(ji,jj) + zat_v * zvtau_ice
         END DO
      END DO
      CALL lbc_lnk( utau, 'U', -1. )   ;   CALL lbc_lnk( vtau, 'V', -1. )   ! lateral boundary condition
      !
      IF(ln_ctl)   CALL prt_ctl( tab2d_1=utau, clinfo1=' lim_sbc: utau   : ', mask1=umask,   &
         &                       tab2d_2=vtau, clinfo2=' vtau    : '        , mask2=vmask )
      !  
   END SUBROUTINE lim_sbc_tau


   SUBROUTINE lim_sbc_init
      !!-------------------------------------------------------------------
      !!                  ***  ROUTINE lim_sbc_init  ***
      !!             
      !! ** Purpose : Preparation of the file ice_evolu for the output of
      !!      the temporal evolution of key variables
      !!
      !! ** input   : Namelist namicedia
      !!-------------------------------------------------------------------
      !
      INTEGER  ::   ji, jj                          ! dummy loop indices
      REAL(wp) ::   zcoefu, zcoefv, zcoeff          ! local scalar
      IF(lwp) WRITE(numout,*)
      IF(lwp) WRITE(numout,*) 'lim_sbc_init : LIM-3 sea-ice - surface boundary condition'
      IF(lwp) WRITE(numout,*) '~~~~~~~~~~~~~   '

      !                                      ! allocate lim_sbc array
      IF( lim_sbc_alloc() /= 0 )   CALL ctl_stop( 'STOP', 'lim_sbc_init : unable to allocate standard arrays' )
      !
      soce_0(:,:) = soce                     ! constant SSS and ice salinity used in levitating sea-ice case
      sice_0(:,:) = sice
      !
      IF( cp_cfg == "orca" ) THEN            ! decrease ocean & ice reference salinities in the Baltic sea 
         WHERE( 14._wp <= glamt(:,:) .AND. glamt(:,:) <= 32._wp .AND.   &
            &   54._wp <= gphit(:,:) .AND. gphit(:,:) <= 66._wp         ) 
            soce_0(:,:) = 4._wp
            sice_0(:,:) = 2._wp
         END WHERE
      ENDIF
      !                                      ! embedded sea ice
      IF( nn_ice_embd /= 0 ) THEN            ! mass exchanges between ice and ocean (case 1 or 2) set the snow+ice mass
         snwice_mass  (:,:) = tms(:,:) * ( rhosn * vt_s(:,:) + rhoic * vt_i(:,:)  )
         snwice_mass_b(:,:) = snwice_mass(:,:)
      ELSE
         snwice_mass  (:,:) = 0.0_wp         ! no mass exchanges
         snwice_mass_b(:,:) = 0.0_wp         ! no mass exchanges
      ENDIF
      IF( nn_ice_embd == 2  .AND.         &  ! full embedment (case 2) & no restart
         &  .NOT. ln_rstart ) THEN           ! deplete the initial ssh below sea-ice area
         sshn(:,:) = sshn(:,:) - snwice_mass(:,:) * r1_rau0
         sshb(:,:) = sshb(:,:) - snwice_mass(:,:) * r1_rau0
         !
         ! Note: Changed the initial values of sshb and sshn=>  need to recompute ssh[u,v,f]_[b,n] 
         !       which were previously set in domvvl
         IF ( lk_vvl ) THEN            ! Is this necessary? embd 2 should be restricted to vvl only???
            DO jj = 1, jpjm1
               DO ji = 1, jpim1                    ! caution: use of Vector Opt. not possible
                  zcoefu = 0.5  * umask(ji,jj,1) / ( e1u(ji,jj) * e2u(ji,jj) )
                  zcoefv = 0.5  * vmask(ji,jj,1) / ( e1v(ji,jj) * e2v(ji,jj) )
                  zcoeff = 0.25 * umask(ji,jj,1) * umask(ji,jj+1,1)
                  sshu_b(ji,jj) = zcoefu * ( e1t(ji  ,jj) * e2t(ji  ,jj) * sshb(ji  ,jj)     &
                     &                     + e1t(ji+1,jj) * e2t(ji+1,jj) * sshb(ji+1,jj) )
                  sshv_b(ji,jj) = zcoefv * ( e1t(ji,jj  ) * e2t(ji,jj  ) * sshb(ji,jj  )     &
                     &                     + e1t(ji,jj+1) * e2t(ji,jj+1) * sshb(ji,jj+1) )
                  sshu_n(ji,jj) = zcoefu * ( e1t(ji  ,jj) * e2t(ji  ,jj) * sshn(ji  ,jj)     &
                     &                     + e1t(ji+1,jj) * e2t(ji+1,jj) * sshn(ji+1,jj) )
                  sshv_n(ji,jj) = zcoefv * ( e1t(ji,jj  ) * e2t(ji,jj  ) * sshn(ji,jj  )     &
                     &                     + e1t(ji,jj+1) * e2t(ji,jj+1) * sshn(ji,jj+1) )
               END DO
            END DO
            CALL lbc_lnk( sshu_b, 'U', 1. )   ;   CALL lbc_lnk( sshu_n, 'U', 1. )
            CALL lbc_lnk( sshv_b, 'V', 1. )   ;   CALL lbc_lnk( sshv_n, 'V', 1. )
            DO jj = 1, jpjm1
               DO ji = 1, jpim1      ! NO Vector Opt.
                  sshf_n(ji,jj) = 0.5  * umask(ji,jj,1) * umask(ji,jj+1,1)                   &
                       &               / ( e1f(ji,jj  ) * e2f(ji,jj  ) )                     &
                       &               * ( e1u(ji,jj  ) * e2u(ji,jj  ) * sshu_n(ji,jj  )     &
                       &                 + e1u(ji,jj+1) * e2u(ji,jj+1) * sshu_n(ji,jj+1) )
               END DO
            END DO
            CALL lbc_lnk( sshf_n, 'F', 1. )
          ENDIF
      ENDIF
      !
   END SUBROUTINE lim_sbc_init

#else
   !!----------------------------------------------------------------------
   !!   Default option :        Dummy module       NO LIM 3.0 sea-ice model
   !!----------------------------------------------------------------------
CONTAINS
   SUBROUTINE lim_sbc           ! Dummy routine
   END SUBROUTINE lim_sbc
#endif 

   !!======================================================================
END MODULE limsbc
