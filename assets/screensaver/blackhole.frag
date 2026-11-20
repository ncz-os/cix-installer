#version 300 es
precision highp float;
precision highp int;
// Scene specialization (defined by blackhole_gles3 after the #version line):
// BH_SCENE 0 single, 1 binary, 2 merger, 3 tidal-disruption, 4 galaxy-zoom,
// 5 three-body; BH_LIGHT 1 selects the thin-lens light mode for weak GPUs.
#ifndef BH_SCENE
#define BH_SCENE 0
#endif
#ifndef BH_LIGHT
#define BH_LIGHT 0
#endif
#if BH_SCENE==1 || BH_SCENE==2 || BH_SCENE==5
#define BH_MULTI 1
#else
#define BH_MULTI 0
#endif
out vec4 fragColor;
// Audio (docs/AUDIO-REACTIVITY.md): the driver maps the shared bus onto the
// saver's own uniforms - u_exposure for the disk and glow, u_jet_duty for the
// jet envelope - and both factors are exactly 1.0 when the layer is off or the
// intensity is 0, so no audio term is evaluated here and this shader needs no
// audio uniform of its own.
// Time-driven palette state: phase + rate are randomised per-launch.
uniform float u_observer_probe, u_close_distance;
uniform float u_stars, u_temperature_profile, u_disk_detail, u_framing;
uniform float u_time, u_seed, u_radius, u_temperature, u_density, u_rotation;
uniform float u_inclination, u_orbit_rate, u_jet, u_star_density;
uniform float u_camera_mode, u_palette, u_approach, u_periapsis;
uniform float u_palette_phase, u_palette_rate, u_palette_contrast;
// Disk colour model. 0 = stylised palette (default, our own art direction).
// 1 = kipthorne: warm blackbody colours. All palettes share physical intensity transport.
// 2 = faithful: blackbody with gravitational redshift AND relativistic
//     Doppler folded into the observed temperature, plus beaming on
//     brightness. Physically correct and visibly asymmetric.
// Colour model derived from hydrogendeuteride/BlackHoleRayTracer (MIT).
// The Planck curve is evaluated analytically rather than sampled from a
// blackbody LUT texture, so no binary asset is required.
// Palettes (ids): 0 stylized, 1 kipthorne, 2 faithful, 3 singularity,
// 4 slingshot, 5 whitehole. u_pal_a/u_pal_b/u_pal_mix cross-fade two palettes
// (mix = 0 renders only palette a).
uniform float u_pal_a, u_pal_b, u_pal_mix;
// Options (see docs/BLACKHOLE-OPTIONS.md). All default to the previous look.
uniform float u_spin, u_isco, u_exposure, u_beaming, u_bloom, u_fringe;
uniform float u_doppler, u_doppler_shift, u_jet_axis, u_jet_opening, u_jet_asymmetry;
float dopplerStrength(){
 if(u_doppler<.5)return 0.;       // off: no Doppler asymmetry or colour shift
 if(u_doppler<1.5)return 1.;      // on: today's full behaviour
 return .25;                      // cinematic: one quarter strength
}
uniform vec4 u_flight_view;
uniform vec3 u_flight_beta,u_flight_velocity;
uniform float u_flight_dust;
uniform vec2 u_flight_film;
uniform float u_lensing, u_nebula_amt, u_hot_sector, u_fade;
// 0 = luminance (hue-preserving) tone map, 1 = classic per-channel Reinhard.
// Disk structure: amplitude of the orbiting hot spots and the spiral wave.
uniform float u_tonemap, u_structure;
// Jet duty envelope (0..1, from C: jets come and go on a slow cycle).
uniform float u_jet_duty;
// Opt-in looks (style=enhanced or set individually): photon ring and bright
// star layer brightness; u_enh = 1 enables jet precession and occlusion.
uniform float u_photon_ring, u_bright_stars, u_enh;
// Artistic gain on physically located orders k >= 2; never duplicate a crossing.
uniform float u_images;
// Twin-jet shaping. u_jet_beaming: Doppler-beaming asymmetry of the two lobes
// (0 = identical, higher = the lobe pointing at the camera brighter). u_jet_
// precess: amplitude multiplier of the slow axis wobble (0 = fixed axis).
// u_jet_width: multiplier on the collimation width. u_jet_color: 0 auto / 1
// palette (palette-tracking), 2 blue, 3 white, 4 orange, 5 cyan.
uniform float u_jet_beaming, u_jet_precess, u_jet_width, u_jet_color;
// Director camera (xyz position, w = 1 when active; up = disk normal),
// burn-in drift of the framing. Legacy spin options do not alter propagation.
// Historical outline coordinates (no longer used): radius in r_s vs
// position angle, 32 columns, rows = inclination 0..90 degrees).
uniform vec4 u_camo;
// Capture-quality mode: sub-pixel jitter (pixels) and output dither switch.
uniform vec2 u_jitter;
uniform float u_dither;
uniform vec2 u_drift;
// Scene extras (presets): outer disk radius, jet length scale, dusty torus
// (opacity, ring radius), companion star with a gas stream (0..1).
uniform float u_disk_out, u_jet_len, u_torus, u_torus_r, u_comp;
// Accretion-flow selector: 0 disk (legacy), 1 torus, 2 RIAF, 3 spherical.
uniform float u_flow, u_flow_extent, u_disk_emission, u_turbulence;
// Per-launch VISUAL VARIANCE (operator, 2026-10-29: "can we also get more random
// variance in the accretion disc and the shadow/event horizon"). Set once in
// main() from u_seed; every launch differs in the disk's texture contrast and
// filament scale, and in the photon ring's brightness and thickness, instead of
// only in palette and camera. Kept as global knobs so the hot paths just read a
// constant-like value.
float g_diskTurb=1., g_diskFreq=1.;
// Corona: the hot optically thin gas above the disk is its OWN component -
// not part of the disk and not a post-process bloom. u_corona 0 disables the
// whole term (the default image is unchanged); u_corona_extent is the radial
// extent in ISCO units; u_corona_temp is the colour-temperature multiplier.
// It is evaluated where the inner flow is: in-plane at the ray/disk crossings
// (so the disk occludes it and it transmits through the disk's attenuation)
// and off-plane in the integrator steps (so the halo extends vertically).
uniform float u_corona, u_corona_extent, u_corona_temp;
// Camera path selector: 0 = legacy per-launch path, 1..8 = orbit, slow-orbit,
// equatorial, polar, plunge, slingshot, drift, sweep. u_fly_t is time in
// cycles, u_fly_var a 0..1 per-cycle variation, u_dmin/u_dmax the distance
// range, u_incl the orbit-plane inclination in radians (<0 = per-type
// default). u_sweep_range / u_sweep_phase (degrees) parameterize the
// inclination sweep (type 8); ignored by every other path.
uniform float u_flyby, u_fly_t, u_fly_var, u_dmin, u_dmax, u_incl, u_sweep_range, u_sweep_phase;
// Per-launch flight-path parameters. Drawn per-launch in C; replace the
// previously-hardcoded curve coefficients so each run traces a distinct
// path shape (not a rescaled version of one).
//   d_base   : base distance (was the 10.5 / 9.8 / 10.8 / 18 literals).
//   d_swing  : amplitude of the cos(phase) radial swing.
//   d_harm_a : secondary dist harmonic amplitude (modes 0, 1, 2).
//   d_harm_f : secondary dist harmonic frequency multiplier.
//   o_rate   : orbital rate multiplier on the phase ramp.
//   o_harm_a : secondary orbital harmonic amplitude (the .28 / .34 / .55).
//   o_harm_f : secondary orbital harmonic frequency multiplier.
//   o_count  : how many orbits before phase wraps; combined with orbit_rate
//              this sets the visible duration of a coherent arc.
//   sign     : +1 prograde, -1 retrograde (flips orbit direction and roll).
//   e_swing  : elevation swing amplitude (the .48..78).
//   e_freq   : elevation swing frequency multiplier on phase.
//   ph_jit   : deterministic per-launch phase offset so launches aren't
//              phase-locked at t=0.
uniform float u_path_d_base, u_path_d_swing, u_path_d_harm_amp, u_path_d_harm_freq;
uniform float u_path_o_rate, u_path_o_harm_amp, u_path_o_harm_freq;
uniform float u_path_o_count, u_path_sign;
uniform float u_path_e_swing, u_path_e_freq, u_path_phase_jitter;
uniform vec2 u_resolution;
// hue, spatial scale, cloud coverage, yaw; tilt and bounded noise offset.
uniform vec4 u_nebula;
uniform vec2 u_nebula_axis;
// Which decorrelation scheme the nebula was given this run (0..2).
uniform float u_nebula_scheme;
// Per-launch disk-axis orientation. xyz is a unit vector along the BH's
// spin axis, drawn uniformly on the sphere (not via naive lat/long, which
// clusters at the poles). w is a half-angle wobble term in [-1,1]: the
// disk normal is the spin axis plus a small in-cone tilt. The disk stays
// near-perpendicular to the spin axis at w=0; |w|=1 lets the disk tilt up
// to ~90° away from the axis. This is what makes edge-on views reachable
// independently of where the camera is.
uniform vec4 u_disk_axis;
// Slow disk precession (Lense-Thirring frame dragging). The disk normal
// swings around u_disk_precess.xyz at rate u_disk_precess.w rad/s. Typical
// launches run 0.02..0.08 rad/s so a minute of capture shows visible but
// unhurried change. The precession axis and rate are both drawn per launch.
uniform vec4 u_disk_precess;
// Handoff viewing geometry (docs/BLACKHOLE-OPTIONS.md). x = observer
// inclination to the disk plane in degrees (0 face-on, 90 edge-on), y = sky
// position angle in degrees (east from north). The host resolves the automatic
// (-1) values to the camera's own angles for the frame it is drawing, so a
// default launch is exactly the pre-handoff image.
uniform vec2 u_view_geom;
// Disk orientation, resolved by the host:
//   xyz = unit spin axis (auto: the per-launch draw),
//   w   = the angle between the spin axis and the disk normal in radians
//         (auto: the per-launch wobble term, still swinging with precession).
// The disk plane is built from this; jets, the shadow and the lensing stay on
// the spin axis, so a misaligned (Lense-Thirring) disk decouples from them.
uniform vec4 u_spin_axis;
// Per-launch trajectory family: 0 = zoom-whirl (bound), 1 = hyperbolic
// flyby (unbound). Drawn 50/50 so both families actually appear.
uniform float u_camera_family;
// Zoom-whirl ratio of angular to radial frequency per radial cycle.
// Rational q -> exactly periodic closed rosette. Irrational q ->
// precesses and NEVER retraces. Drawn per-launch; defaults to a
// value just above 1 for the flyby family (where it is unused).
uniform float u_orbit_q;
// Orbital eccentricity (zoom-whirl: 0.15..0.7; flyby: > 1).
uniform float u_orbit_e;
// Argument of periapse (radians). The orbit's periapse direction;
// rotates the swept arc around the focus. Drawn [0, 2pi] per launch.
uniform float u_orbit_omega;
uniform float u_max_steps;
// ---- scene state (see src/blackhole_scenes.h; unused uniforms are compiled out)
uniform vec4 u_holes[3];   // xyz position in the orbital plane z = 0, w = r_s (0 = absent)
uniform vec4 u_scn;        // minidisk outer radius (own r_s), circumbinary inner, outer, brightness
uniform vec4 u_gw;         // ripple amplitude, orbital omega0, t_c, phase0
uniform vec4 u_gw2;        // scene time, merge time (<0 none), wave speed, ringdown omega
uniform vec4 u_fx;         // merger flash, ringdown wobble, minidisk visibility, remnant r_s
uniform vec4 u_tde;        // star position, star radius
uniform vec4 u_tde2;       // time since pericenter, r_p, pericenter angle, orbit sense
uniform vec4 u_tde3;       // tidal stretch, flare, disk outer radius, disk brightness
uniform vec4 u_gal;        // arms, pitch, disk scale length, rotation phase
uniform vec4 u_gal2;       // hue, dust, bulge sigma, variation
uniform vec4 u_zoom;       // camera distance (0 = path), star scale, nebula scale, galaxy brightness
#define PI 3.14159265358979323846
float g_dout=12.;          // outer disk radius used by disk_color (per disk in the scenes)
float g_cov=0.;
float g_soft=1.;           // softness of the disk's outer edge (TDE: diffuse)
vec3 g_cam=vec3(0.);       // camera position (scene helpers)
float g_fw=.002;
float g_dz=1.;             // |z| of the ray direction at the current plane crossing           // angular size of a pixel (radians), for scene anti-aliasing            // set by shadePlane when a crossing lands on some disk
// Keep seeded spatial offsets small before adding fractional coordinates.
// A uint32-sized float seed times .01 erases sub-cell detail (ulp up to 4).
float noiseSeed(){return mod(u_seed,8191.);}
float hash21(vec2 p){p=fract(p*vec2(123.34,345.45));p+=dot(p,p+34.345+noiseSeed()*.00001);return fract(p.x*p.y);}
// BAKED NOISE (2026-10-29). The value-noise fbm used to be evaluated per
// pixel from hash21 above: sixteen hash evaluations per fbm call, and the
// disk's turbulence path calls fbm nine times per sample. The four octaves
// are now baked once on the CPU (src/bh_noise_bake.h) into a tileable RGBA8
// texture, and the shader reads them with one fetch instead.
//
// Channels: R = the base value-noise octave, G = the four-octave fbm sum,
// B = the base octave at twice the frequency, A = the base octave at four
// times the frequency.
//
// u_noise_on is 0 when the host could not bake the texture (or the user
// turned the baked path off), and the procedural path below is used
// unchanged. The two paths are numerically different but statistically
// equivalent, so the fallback renders the same look, just slower.
//
// NOTE: only the 2D PLANE noise is baked. The direction-space noise
// (skyNoise, below) stays procedural on purpose: it is sampled over the
// whole sphere, and a 2D texture would put a longitude seam and a pole
// singularity back into the sky, exactly what that function's comment
// warns about.
uniform sampler2D u_noise_tex;
uniform float u_noise_on; /* u_noise_size removed: declared here but never read (baked map is UV-addressed in texture space) */
// The tile spans `cells` base lattice cells; the baked field's period is
// that many cells, so a UV coordinate of p means p/cells tiles.
#define BH_NOISE_CELLS 64.0
// Five-fetch tent -> the baked fbm sum. p is in BASE LATTICE CELLS (the unit
// the procedural noise() took); the bake's octave 0 has exactly that period.
// The wrap-around tent (centre + the four axis neighbours at one texel)
// smooths the bake's 8-bit dither/quantisation residual; without it the
// baked path shows radial luma steps the seam gate (pass3) rejects, while
// the unquantised procedural path passes. The bake tile repeats, so the
// taps wrap seamlessly wherever the sampler is set to GL_REPEAT.
vec4 bakedFetch(vec2 uv){
 vec2 e=1./vec2(textureSize(u_noise_tex,0));
 vec4 t=texture(u_noise_tex,uv)*.2;
 t+=(texture(u_noise_tex,uv+vec2(e.x,0.))+texture(u_noise_tex,uv-vec2(e.x,0.)))*.2;
 t+=(texture(u_noise_tex,uv+vec2(0.,e.y))+texture(u_noise_tex,uv-vec2(0.,e.y)))*.2;
 return t;
}
float bakedFbm(vec2 p){
 vec2 uv=p/BH_NOISE_CELLS+0.5;                       // the tile is one unit across
 return bakedFetch(uv).g;
}
// One bakedFetch -> a single value-noise octave at the given frequency
// multiple (1, 2 or 4). The higher multiples come from the baked B and A
// channels.
float bakedNoise(vec2 p,float freq){
 vec2 uv=p/BH_NOISE_CELLS+0.5;
 vec4 t=bakedFetch(uv);
 if(freq>3.)return t.a;
 if(freq>1.5)return t.b;
 return t.r;
}
float noise(vec2 p){
 if(u_noise_on>0.5)return bakedNoise(p,1.);
 vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(hash21(i),hash21(i+vec2(1,0)),f.x),mix(hash21(i+vec2(0,1)),hash21(i+1.),f.x),f.y);}
float fbm(vec2 p){
 if(u_noise_on>0.5)return bakedFbm(p);
 float v=0.,a=.5;for(int i=0;i<4;i++){v+=a*noise(p);p=p*2.03+vec2(17.13,-11.7);a*=.5;}return v;}

// ---- HSL helpers (palette interpolation in hue-space avoids the grey
//      midpoint that linear-RGB complement mixing passes through) ----
vec3 hsl2rgb(vec3 c){vec3 rgb=clamp(abs(mod(c.x*6.+vec3(0.,4.,2.),6.)-3.)-1.,0.,1.);return c.z+c.y*(rgb-.5)*(1.-abs(2.*c.z-1.));}
// Each palette is a list of (hue_offset, sat, lum) stops. u_palette selects
// the family; the active hue rotates with u_time via u_palette_phase + rate.
struct Stop{float h,s,l;};
// Hue interpolation along the SHORT arc so wrapping never produces a jump.
float hueLerp(float a,float b,float k){float d=b-a;d-=floor(d+.5);return a+d*k;}
Stop stopAHue(Stop a,Stop b,float k){return Stop(hueLerp(a.h,b.h,k),a.s+(b.s-a.s)*k,a.l+(b.l-a.l)*k);}

// Five named palettes + a sixth "psychedelic" used when u_palette>=5.
// Each is a 4-stop ramp. Stops chosen to span temperature hot->cool with
// at least two clearly different hues so a single disk carries several
// colours at once. Saturation is high but not maxed out so the disk does
// not crush to neon; one named palette (3, ultraviolet) is intentionally
// restrained for the "classical" look.
void paletteStops(float idx,out Stop s0,out Stop s1,out Stop s2,out Stop s3){
 if(idx<.5){                              // solar gold (warm, restrained)
  s0=Stop(.085,.85,.10); s1=Stop(.085,.90,.42);
  s2=Stop(.07,.95,.72);  s3=Stop(.04,.75,.98);
 }else if(idx<1.5){                       // blue-hot
  s0=Stop(.62,.80,.08);  s1=Stop(.55,.95,.34);
  s2=Stop(.48,.85,.66);  s3=Stop(.52,.60,.98);
 }else if(idx<2.5){                       // ember (deep red->orange->yellow)
  s0=Stop(.97,.95,.06);  s1=Stop(.05,.98,.32);
  s2=Stop(.10,.95,.62);  s3=Stop(.13,.80,.97);
 }else if(idx<3.5){                       // ultraviolet (classical, restrained)
  s0=Stop(.72,.90,.06);  s1=Stop(.78,.80,.30);
  s2=Stop(.82,.70,.58);  s3=Stop(.86,.55,.96);
 }else if(idx<4.5){                       // exotic mint -> magenta split
  s0=Stop(.42,.65,.10);  s1=Stop(.50,.95,.36);
  s2=Stop(.86,.85,.62);  s3=Stop(.92,.90,.96);
 }else{                                   // psychedelic: 4 widely-separated hues
  s0=Stop(.00,.90,.10);  s1=Stop(.18,.95,.40);
  s2=Stop(.55,.95,.66);  s3=Stop(.82,.90,.98);
 }
}
vec3 palette(float t){
 // Active hue offset: drifts continuously over time, randomised per-launch.
 float active_h=u_palette_phase+u_time*u_palette_rate;
 Stop s0,s1,s2,s3;paletteStops(u_palette,s0,s1,s2,s3);
 // Map the 4 stops into a hue-rotated frame so each stop's hue advances by
 // active_h (mod 1). Keeps relative relationships, adds global drift.
 s0.h=fract(s0.h+active_h); s1.h=fract(s1.h+active_h);
 s2.h=fract(s2.h+active_h); s3.h=fract(s3.h+active_h);
 // 4-stop ramp interpolated with hue-space lerp (no grey midpoint).
 // Branches on t so each segment interpolates only between adjacent stops.
 Stop r;
 if(t<.33)r=stopAHue(s0,s1,t/.33);
 else if(t<.66)r=stopAHue(s1,s2,(t-.33)/.33);
 else if(t<.90)r=stopAHue(s2,s3,(t-.66)/.24);
 else r=s3;
 return hsl2rgb(vec3(r.h,r.s,r.l));
}

// Direction-space noise has no longitude seam or pole singularity.
float flightStreak(float speed){return .035*clamp(speed,0.,2.);}
// Observer sightline -> static tetrad; exact inverse Lorentz aberration.
vec3 flightAberration(vec3 n,vec3 beta,out float doppler){
 float b2=dot(beta,beta),g=inversesqrt(max(1.-b2,1e-6)),bn=dot(beta,n);
 doppler=1./(g*(1.-bn));
 return (n+((g-1.)*bn/max(b2,1e-20)-g)*beta)/(g*(1.-bn));
}
float skyHash(vec3 p){p=fract(p*.1031);p+=dot(p,p.yzx+33.33);return fract((p.x+p.y)*p.z);}
float skyNoise(vec3 p){
 vec3 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);
 return mix(mix(mix(skyHash(i),skyHash(i+vec3(1,0,0)),f.x),
                mix(skyHash(i+vec3(0,1,0)),skyHash(i+vec3(1,1,0)),f.x),f.y),
            mix(mix(skyHash(i+vec3(0,0,1)),skyHash(i+vec3(1,0,1)),f.x),
                mix(skyHash(i+vec3(0,1,1)),skyHash(i+vec3(1,1,1)),f.x),f.y),f.z);
}
// Linear radiance scaled by four in RGBA8; alpha is linear transmission.
// No procedural cloud work survives in the per-frame sky path.
uniform samplerCube u_sky_tex;
uniform float u_sky_ready;
uniform float u_lens_boost;
uniform float u_ejecta, u_ejecta_rate, u_ejecta_burst;
uniform sampler2D u_galaxy_tex, u_galaxy_near_tex;
uniform float u_galaxy_kind, u_galaxy_nucleus;
// Artistic gain on the escaped background only. Identity returns the original
// vector without normalization, preserving the exact GR result at gain <= 1.
vec3 boostSky(vec3 original,vec3 escaped){
 if(u_lens_boost<=1.)return escaped;
 vec3 axis=cross(original,escaped);float sine=length(axis);
 if(sine<1e-6)return escaped;
 axis/=sine;float a=atan(sine,dot(original,escaped))*(u_lens_boost-1.);
 return escaped*cos(a)+cross(axis,escaped)*sin(a)+axis*dot(axis,escaped)*(1.-cos(a));
}
vec4 skySample(vec3 d){
 if(u_sky_ready<.5)return vec4(0.,0.,0.,1.);
 vec4 sky=texture(u_sky_tex,d);sky.rgb*=.25;return sky;
}
// B-V proxy ramp: blue O/B, neutral A/F, warm G/K, red M. Linear RGB.
vec3 spectralStar(float bv){
 return bv<.45?mix(vec3(.45,.62,1.),vec3(1.),clamp((bv+.4)/.85,0.,1.)):
 mix(vec3(1.),vec3(1.,.32,.10),clamp((bv-.45)/1.55,0.,1.));
}
// Star placement hashes. hash21 (fract(p*const) then a dot-product fold) leaves lattice correlations between the
// independent jitter lookups, which showed up as rows/columns of identical dots ("old Atari" look, operator 2026-11-08).
float sh1(vec2 p){vec3 q=fract(vec3(p.xyx)*.1031);q+=dot(q,q.yzx+33.33);return fract((q.x+q.y)*q.z);}
vec2 sh2(vec2 p){vec3 q=fract(vec3(p.xyx)*vec3(.1031,.1030,.0973));q+=dot(q,q.yzx+33.33);return fract((q.xx+q.yz)*q.zy);}
// One star layer on an equal-angle cube-map grid of K x K cells per face. dens = probability a cell holds a star;
// magnitudes follow a steep power law (many faint, few bright); radius grows with brightness; colour comes from a
// B-V proxy, with faint stars pulled toward white. Returns linear RGB and, in spike, a 0..1 diffraction-cross weight.
vec3 starLayer(vec2 fuv,float fid,float K,float dens,float seedOff,float rMin,float rMax,float amp,float arcStretch,vec2 screenT,out float spike){
 vec2 g=(fuv*.5+.5)*K;
 vec2 cell=floor(g),f=fract(g);
 vec2 hc=cell+vec2(fid*37.1,fid*91.7)+seedOff+mod(u_seed,8191.);
 spike=0.;
 if(sh1(hc)>dens)return vec3(0.);
 float u=sh1(hc+17.3);
 float mag=u*u*u;                                   // P(mag>.5) = 12.5 percent
 vec2 sp=sh2(hc+3.1)*.7+.15;
 vec2 delta=f-sp;
 vec2 tangent=vec2(1.,0.);
 if(arcStretch>0.)tangent=normalize(dFdx(g)*screenT.x+dFdy(g)*screenT.y+vec2(1e-5));
 float along=dot(delta,tangent),across=dot(delta,vec2(-tangent.y,tangent.x));
 float dist=length(vec2(along/(1.+arcStretch),across));
 float rad=mix(rMin,rMax,sqrt(mag));
 float s=1.-smoothstep(0.,rad,dist);
 vec3 c=spectralStar(2.4*sh1(hc+7.)-.4);
 c=mix(vec3(1.),c,.45+.55*mag);
 float tw=.94+.06*sin(u_time*.35+u*40.);
 // a few of the brightest stars get a faint 4-point diffraction cross in the lens-stretched tangent frame
 if(mag>.72){
  float a=abs(along),b=abs(across);
  spike=(exp(-b*46.)*exp(-a*9.)+exp(-a*46.)*exp(-b*9.))*smoothstep(.72,1.,mag);
 }
 return c*s*s*tw*amp*(.10+1.9*mag);
}
vec3 stars(vec3 d,float fw,float arcStretch,vec2 screenT){
 if(u_stars<.5||u_star_density<=0.)return vec3(0.);
 // Star field hashed in DIRECTION space (equal-angle cube map), not a lat/long grid (poles packed cells into
 // searchlight patches). Three layers: fine faint dust, a main field, and sparse bright stars; stars are denser
 // along a per-launch galactic band so the sky has structure instead of an even sprinkle.
 vec3 ad=abs(d);
 float m=max(max(ad.x,max(ad.y,ad.z)),1e-6);
 vec2 fuv;float fid;
 if(ad.x>=ad.y&&ad.x>=ad.z){fuv=d.yz/m;fid=d.x>0.?0.:1.;}
 else if(ad.y>=ad.z){fuv=d.xz/m;fid=d.y>0.?2.:3.;}
 else{fuv=d.xy/m;fid=d.z>0.?4.:5.;}
 fuv=atan(fuv)*(4./PI);                       // equal-angle, [-1,1]
 vec3 bn=normalize(vec3(sh1(vec2(mod(u_seed,8191.),1.))-.5,sh1(vec2(mod(u_seed,8191.),2.))-.5,sh1(vec2(mod(u_seed,8191.),3.))-.5)+vec3(1e-4));
 float band=exp(-pow(dot(d,bn)/.24,2.));       // 1 on the band's great circle, ~0 away from it
 float dens=u_star_density*(.55+2.4*band);
 float sp1,sp2,sp3;
 vec3 col=starLayer(fuv,fid,420.,.018*dens,501.,.07,.11,1.15,arcStretch,screenT,sp1);   // dust
 col+=starLayer(fuv,fid,208.,.013*dens,0.,.09,.17,3.0,arcStretch,screenT,sp2);          // main field
 if(u_bright_stars>0.)
  col+=u_bright_stars*starLayer(fuv,fid,48.,.12*min(u_star_density,1.5),311.,.030,.052,3.2,arcStretch,screenT,sp3)*(1.+2.2*sp3);
 return col;
}
// ---- Disk axis tilt ----
// Build the world-space disk normal at the current time. Two contributions:
//   1. Per-launch spin axis drawn uniformly on the sphere (u_disk_axis.xyz).
//      w is a half-angle wobble term in [-1,1] which tilts the disk up to
//      ~90° away from the axis at |w|=1.
//   2. Slow precession about u_disk_precess.xyz at rate u_disk_precess.w.
// Both motions are physically motivated: a BH's spin axis is fixed on a
// human time scale; the DISK misaligns with the spin axis and precesses
// via Lense-Thirring frame dragging. Keeping the precession slow means a
// viewer notices it over a minute, not as a tumble.
vec3 diskNormalAtTime(float t){
 // The resolved spin axis (u_spin_axis.xyz) and the resolved tilt between the
 // disk normal and that axis (u_spin_axis.w). With the automatic values these
 // are exactly the per-launch draws above (wobble * pi/2), so the motion - and
 // the image - are unchanged; the options pin them instead.
 vec3 spin=u_spin_axis.xyz;
 vec3 ref=abs(spin.z)>.97?vec3(1.,0.,0.):vec3(0.,0.,1.);
 vec3 perp=cross(spin,ref);
 float pl=length(perp);
 vec3 perpN=pl>1e-4?perp/pl:vec3(1.,0.,0.);
 // Tilt away from the axis. A pinned spin axis (from --disk-tilt or the
 // spin-axis options) fixes the azimuth of the tilt in the plane of the sky:
 // the tilted normal leans toward north (up), which is how a position angle
 // is drawn on the sky. With the automatic axis the reference is a fixed
 // world +Z, as before, so the draw reproduces the original frame.
 float tilt=u_spin_axis.w;
 vec3 lean=perpN;
 if(u_view_geom.y>=0.){
  vec3 axisN=spin/max(length(spin),1e-5);            // exact as drawn, never 0
  vec3 north=vec3(0.,0.,1.)-axisN*dot(axisN,vec3(0.,0.,1.));
  float nl=length(north);
  if(nl>1e-4)lean=north/nl;
 }
 float cw=cos(tilt),sw=sin(tilt);
 vec3 tilted=cw*spin+sw*lean;
 // Precession: swing tilted about u_disk_precess.xyz. Rodrigues rotation.
 vec3 pAxis=u_disk_precess.xyz;
 float pa=length(pAxis);
 // If pAxis is degenerate (essentially zero), skip the precession and
 // return the tilted vector. The probability of this from a uniform draw
 // is exactly zero; the guard is here for safety only.
 if(pa<1e-4)return normalize(tilted+vec3(0.,0.,1e-4));
 vec3 pN=pAxis/pa;
 float ang=t*u_disk_precess.w;
 float c=cos(ang),sang=sin(ang);
 float dotN=dot(pN,tilted);
 vec3 swung=tilted*c+cross(pN,tilted)*sang+pN*(dotN*(1.-c));
 return normalize(swung);
}
// ---- Observing geometry: inclination and position angle ------------------
// The remaining two handoff controls describe where the OBSERVER stands, so
// they are applied to the view, never to the disk: the disk, its spin axis and
// its lensed images stay fixed in the world and the observer moves around
// them. That is what makes the options mean what they say:
//   * inclination: 0 looks down the disk normal (a round ring), 90 looks
//     along the disk plane (a thin line), and in between the lensed far side
//     of the disk arches over the shadow - the same ray path produces the
//     far-side image, so it follows automatically;
//   * position angle: turns the whole image about the shadow in the sky;
//   * the disk plane stays independent of the spin axis (disk tilt), while
//     the jets, the shadow and the photon ring ride the spin axis.
// The hole is at the origin and both angles only move the eye on a sphere
// about it, so the composition never changes - the image turns underneath.
//
// The observer basis is built directly from the two angles (rather than by
// composing two rotations), which keeps it well conditioned at every angle
// including the exact pole and the exact edge-on view:
//   lineOfSight = (cos(el) cos(pa), cos(el) sin(pa), sin(el)),  el = 90 - inc
//   right = normalize(los x +Z)        (horizontal in the sky)
//   up    = right x los
// A ray cast in this basis reaches the world point right*ndc.x + up*ndc.y
// + los (the eye is toward the camera), so world vectors are recovered with
// the matrix whose ROWS are right, up, -los - that is the world -> observer
// map (eye space: +X right, +Y up, +Z toward the eye).
struct ViewXform { vec3 right, up, los; vec3 cam; };
float wrapDeg(float d){return fract(d/360.)*360.;}   // continuous, bounded
ViewXform viewXform(vec3 camWorld){
 float inc=radians(wrapDeg(u_view_geom.x));            // from the disk plane
 float pa =radians(wrapDeg(u_view_geom.y));            // east of north
 float el=1.5707963-inc;                               // elevation above it
 vec3 los=vec3(cos(el)*cos(pa),cos(el)*sin(pa),sin(el));
 // Nail the two degenerate cases: exactly face-on (los = +-Z) needs a stable
 // "right", and exactly edge-on leaves the projection of the disk a segment.
 if(abs(los.z)>0.99999){
  los=normalize(vec3(sign(los.z)*cos(el),0.,sin(el)));
 }
 vec3 right=cross(los,vec3(0.,0.,1.));
 if(length(right)<1e-6)right=vec3(cos(pa),sin(pa),0.);   // face-on: keep the PA
 right=normalize(right);
 vec3 up=cross(right,los);
 ViewXform v;
 v.right=right;v.up=up;v.los=los;
 // The eye keeps the path's distance and sits along the new line of sight. The
 // rays are built in this basis, so only the eye's distance matters for the
 // projection; the hole stays at the origin.
 v.cam=los*max(length(camWorld),1e-4);
 return v;
}
// An eye-basis direction (right, up, toward the eye) back in the world. This
// is the only eye->world map the frame needs: the view ray is built in the
// eye basis and everything downstream stays in world space.
vec3 toWorld(ViewXform v,vec3 e){return v.right*e.x+v.up*e.y-v.los*e.z;}
// Rotate a world-space point into the frame where the disk sits in the XY
// plane (normal +Z). Equivalent to applying the inverse of the rotation
// that maps +Z to diskNormal. Implemented as Rodrigues' rotation about the
// axis (diskNormal x +Z).
vec3 toDiskLocal(vec3 p,vec3 n){
 vec3 cz=cross(n,vec3(0.,0.,1.));
 if(length(cz)<1e-5)return n.z<0.?vec3(p.x,-p.y,-p.z):p; // antipode: half-turn about X
 vec3 axis=normalize(cz);
 float ang=acos(clamp(n.z,-1.,1.));    // angle from world +Z
 float c=cos(ang),s=sin(ang);
 return p*c + cross(axis,p)*s + axis*dot(axis,p)*(1.-c);
}
// Analytic blackbody colour over ~1000K..40000K, approximating the Planck
// locus in sRGB - the same curve a blackbody LUT texture bakes.
vec3 blackbodyRGB(float kelvin){
 float t=clamp(kelvin,1000.,40000.)/100.;
 float r,g,b;
 if(t<=66.) r=1.; else r=clamp(1.292936186*pow(t-60.,-0.1332047592),0.,1.);
 if(t<=66.) g=clamp(0.3900815788*log(max(t,1.))-0.6318414438,0.,1.);
 else       g=clamp(1.129890861*pow(t-60.,-0.0755148492),0.,1.);
 if(t>=66.)      b=1.;
 else if(t<=19.) b=0.;
 else            b=clamp(0.5432067892*log(t-10.)-1.196254089,0.,1.);
 return vec3(r,g,b);
}

float g_hit=0.;   // index of the disk crossing being shaded (0 = primary image)
vec3 srgbLin(vec3 c){return pow(c,vec3(2.2));}
// Piecewise-linear color ramp with 5 stops (already linear light), x in 0..1.
vec3 ramp5(float x,vec3 c0,vec3 c1,vec3 c2,vec3 c3,vec3 c4){
 float t=clamp(x,0.,1.)*4.;
 if(t<1.)return mix(c0,c1,t);
 if(t<2.)return mix(c1,c2,t-1.);
 if(t<3.)return mix(c2,c3,t-2.);
 return mix(c3,c4,t-3.);
}
// Saturation about luma. The analytic blackbody fit is pale in sRGB and the
// tonemap pulls it further toward white, so the physical modes boost it.
vec3 satBoost(vec3 c,float k){float l=dot(c,vec3(.299,.587,.114));return max(mix(vec3(l),c,k),vec3(0.));}
// Disk color and brightness factor for one palette. Everything the palette
// contributes lives here so two palettes can be cross-faded.
// OKLab (Ottosson 2020) for palette cross-fades: a straight mix in linear RGB
// between, e.g., magenta and cyan passes through grey; OKLab keeps lightness
// and chroma along the way.
vec3 lin2oklab(vec3 c){
 vec3 l=vec3(.4122214708*c.r+.5363325363*c.g+.0514459929*c.b,.2119034982*c.r+.6806995451*c.g+.1073969566*c.b,.0883024619*c.r+.2817188376*c.g+.6299787005*c.b);
 l=pow(max(l,vec3(0.)),vec3(1./3.));
 return vec3(.2104542553*l.x+.7936177850*l.y-.0040720468*l.z,1.9779984951*l.x-2.4285922050*l.y+.4505937099*l.z,.0259040371*l.x+.7827717662*l.y-.8086757660*l.z);
}
vec3 oklab2lin(vec3 c){
 vec3 l=vec3(c.x+.3963377774*c.y+.2158037573*c.z,c.x-.1055613458*c.y-.0638541728*c.z,c.x-.0894841775*c.y-1.2914855480*c.z);
 l=l*l*l;
 return vec3(4.0767416621*l.x-3.3077115913*l.y+.2309699292*l.z,-1.2684380046*l.x+2.6097574011*l.y-.3413193965*l.z,-.0041960863*l.x-.7034186147*l.y+1.7076147010*l.z);
}
vec3 mixOk(vec3 a,vec3 b,float k){
 // OKLab is defined on display-range values; normalize by the larger
 // component first so over-range emission does not skew the blend.
 float m=max(max(max(a.r,a.g),max(a.b,b.r)),max(max(b.g,b.b),1e-4));
 return max(oklab2lin(mix(lin2oklab(a/m),lin2oklab(b/m),k)),vec3(0.))*m;
}
// The exact single-hole tier shares one transport layer across every palette.
vec3 g_photon=vec3(0.);
float g_observer=1.;
uniform highp sampler2DArray u_tr_forward,u_tr_inverse;
uniform highp sampler2D u_tr_ends;
float trTex(highp sampler2DArray atlas,int x,int row){
 return texelFetch(atlas,ivec3(x,row%2048,row/2048),0).r;
}
float trSample(highp sampler2DArray atlas,float x,float row){
 vec2 q=vec2(clamp(x,0.,1.)*511.,row);
 ivec2 a=ivec2(floor(q));vec2 w=fract(q);
 int y1=min(a.y+1,a.y<2048?2047:4095);
 return mix(mix(trTex(atlas,a.x,a.y),trTex(atlas,min(a.x+1,511),a.y),w.x),
            mix(trTex(atlas,a.x,y1),trTex(atlas,min(a.x+1,511),y1),w.x),w.y);
}
vec2 trEnds(float row){
 int y=int(floor(row)),y1=min(y+1,y<2048?2047:4095);
 return mix(texelFetch(u_tr_ends,ivec2(y%2048,y/2048),0).rg,texelFetch(u_tr_ends,ivec2(y1%2048,y1/2048),0).rg,fract(row));
}
float trRow(float b){
 float delta=b/2.598076211353316-1.;
 float t=(log(max(abs(delta),exp(-16.)))+16.)/(delta>0.?23.6246189861594:15.999999);
 return (delta>0.?2048.:0.)+clamp(t,0.,1.)*2047.;
}
// Shared bolometric Liouville transport (static Schwarzschild observer).
float transportG4(float doppler,float metric){
 float g=doppler*sqrt(max(metric,0.)/g_observer);float g2=g*g;return g2*g2;
}
vec3 palTint(float mode,float hm,float dop,float grav,float r,float a,float paletteT,float sector,float drama){
 float dopE=1.;
 if(mode<.5){
  // stylized: unchanged look, hot sector gated by the option (default 0.22)
  float boost=1.+u_hot_sector*drama*sector*(1.-smoothstep(4.,8.,r));
  return palette(paletteT)*dopE*dopE*boost;
 }
 if(mode<1.5){
  // kipthorne: symmetric warm blackbody, no Doppler, redshift or beaming
  return satBoost(blackbodyRGB(mix(1900.,4300.,hm)),1.4)*(.85+.35*hm);
 }
 // Colour response receives the same local Doppler factor as transport.
 float D=dop;
 float Dcolor=mix(1.,D,u_doppler_shift*dopplerStrength());
 // Extrapolation at shift > 1 can cross zero on the receding side.
 Dcolor=max(Dcolor,.001);
 if(mode<2.5){
  float gColor=Dcolor*grav;
  // One shift factor g = D * sqrt(1 - r_s/r) for both the spectrum (observed
  // temperature ~ g, drawn through g^2 for legibility) and the intensity
  // (bolometric ~ g^4); the clamp is wide and the luminance tone map carries
  // the lopsided crescent.
  // Photographic material: continuous linear-light red-brown -> amber ->
  // white-blue, with the observed temperature moving under Doppler shift.
  float h=smoothstep(.0,1.,clamp((hm-.28)*1.65*gColor,0.,1.));
  vec3 c=ramp5(h,srgbLin(vec3(.13,.025,.012)),srgbLin(vec3(.48,.105,.035)),
               srgbLin(vec3(.90,.38,.11)),srgbLin(vec3(1.,.82,.56)),
               srgbLin(vec3(.88,.94,1.)));
  return c*.75;
 }
 if(mode<3.5){
  // singularity: the Singularity desktop look, white on black. Sampled from
  // its default wallpaper: background #000000, mark #ffffff, neutral greys.
  float d3=1.;
  vec3 c=mix(vec3(.985,.99,1.),vec3(1.),hm);
  return c*mix(.5,1.,hm)*1.25*d3*d3;
 }
 if(mode<4.5){
  // slingshot: brick/rust disk, orange -> gold -> near white where beaming is
  // strongest, blue-white limb on the secondary (lensed) image.
  float g=Dcolor*grav;
  float x=clamp(pow(g,1.15)*(.30+.70*hm)*.95,0.,1.);
  vec3 c=ramp5(x,srgbLin(vec3(.365,.125,.078)),srgbLin(vec3(.69,.29,.165)),srgbLin(vec3(1.,.70,.28)),srgbLin(vec3(1.,.88,.54)),srgbLin(vec3(1.,.953,.784)));
  if(g_hit>.5)c=mix(c,srgbLin(vec3(.812,.890,1.)),.5);
  return c*(.85*(.6+.8*hm));
 }
 if(mode>6.5&&mode<7.5){
  // psychedelic: rainbow bands flowing with the orbit and radius, cycling
  // through the whole spectrum over time. Angle enters only through sin()
  // (periodic), so there is no seam at a = +-PI.
  float hh=fract(.16*sin(a)+.08*sin(2.*a+u_time*.21)+.85*hm+(r-3.)*.055-u_time*.03+u_palette_phase);
  vec3 c=hsl2rgb(vec3(hh,1.,.30+.36*hm));
  float d7=1.;
  return c*(.85+1.1*hm)*d7*d7*1.5;
 }
 if(mode>8.5){
  // cygnus (NCZ-OS 26.10 identity): hot magenta #E0309E and cyan #22D3EE on
  // violet-black. The approaching side runs cyan, the receding side magenta,
  // blended in OKLab (no grey midpoint), and only the hottest inner light
  // pales toward white.
  vec3 mg=srgbLin(vec3(.878,.188,.620)),cy=srgbLin(vec3(.133,.827,.933));
  float k=smoothstep(.80,1.30,mix(1.,dop,max(u_beaming,.35)*dopplerStrength()*u_doppler_shift));
  vec3 c=mixOk(mg,cy,k);
  c=mix(c,vec3(1.),.45*hm*hm*hm);
  float d9=1.;
  return c*(.30+1.25*hm)*d9*d9*1.35;
 }
 if(mode>7.5){
  // synthwave: deep indigo -> violet -> magenta -> hot pink, cyan-white core.
  float x=clamp(.10+.95*pow(hm,.8)*mix(1.,dop,.35*u_beaming*dopplerStrength()*u_doppler_shift),0.,1.);
  vec3 c=ramp5(x,srgbLin(vec3(.10,.02,.20)),srgbLin(vec3(.36,.10,.55)),srgbLin(vec3(1.,.18,.63)),srgbLin(vec3(1.,.54,.36)),srgbLin(vec3(.72,.98,1.)));
  float d8=1.;
  return c*1.25*d8*d8;
 }
 if(mode>5.5){
  // eht: Event Horizon Telescope false color (afmhot): dark red through orange
  // to pale yellow, with a bright crescent on the approaching side.
  float g=Dcolor*grav;
  float x=clamp(pow(clamp(Dcolor*Dcolor*Dcolor,.05,6.)*(.25+.75*hm),.62)*.55*pow(g,.3),0.,1.);
  vec3 c=ramp5(x,srgbLin(vec3(.06,.01,.0)),srgbLin(vec3(.45,.09,.0)),srgbLin(vec3(.86,.34,.03)),srgbLin(vec3(1.,.72,.30)),srgbLin(vec3(1.,.96,.80)));
  return c*1.05;
 }
 // whitehole: icy, symmetric and calm. Ramp from deep teal-navy at the outer
 // glow through steel blue, teal/seafoam and ice blue to a pure white core.
 float x=clamp(.12+1.05*pow(hm,.9),0.,1.);
 vec3 c=ramp5(x,srgbLin(vec3(.063,.20,.29)),srgbLin(vec3(.227,.427,.561)),srgbLin(vec3(.31,.816,.784)),srgbLin(vec3(.812,.91,1.)),vec3(1.));
 // faint chromatic fringe: cyan on the inner edge, magenta on the outer edge
 float ein=1.-smoothstep(0.,.7,r-u_isco),eout=smoothstep(g_dout-4.,g_dout-1.5,r)*(1.-smoothstep(g_dout-1.5,g_dout+.5,r));
 c+=u_fringe*(vec3(-.05,.30,.36)*ein+vec3(.36,-.04,.38)*eout);
 float d5=1.;
 return max(c,vec3(0.))*1.15*d5;
}
// Page-Thorne Schwarzschild flux shape, x=sqrt(r/M)=sqrt(2r/rs).
// Normalised to unit peak (r/rs approximately 4.775); zero torque at 3 rs.
float pageThorneFlux(float r){
 // Enforce the zero-torque boundary before subtracting nearly equal fp32
 // terms; AMD can otherwise leave a positive residual at exactly 3 rs.
 if(r<=3.)return 0.;
 float x=sqrt(2.*max(r,3.)),x0=sqrt(6.),a=sqrt(3.);
 float integral=x-x0-.5*a*log(((x-a)/(x+a))*((x0+a)/(x0-a)));
 return max(integral,0.)/(x*x*x*x*x*(x*x-3.))/.0001146;
}
vec3 disk_color(vec3 p,vec3 diskN,float drama){
 // Rotate into the disk's local frame (z = disk normal at this instant).
 // Everything below runs in plane-polar (r, a) where a is the orbital
 // angle around the disk axis. The seam rule still applies: a is atan(...)
 // and discontinuous, so anything driven by it (bandHue here) MUST be
 // periodic in it.
 vec3 pL=toDiskLocal(p,diskN);
 float r=length(pL.xy),a=atan(pL.y,pL.x);
 // Differential (Keplerian) rotation winds any texture tighter without end:
 // after tens of minutes the disk turned into fine concentric stripes that
 // shimmered from frame to frame (30-minute captures, 2026-09-29). The shear
 // restarts every TW seconds; around each restart a second copy (offset by
 // TW/2, so it is mid-window then) cross-fades in over FW seconds and hides
 // the reset. Outside those windows only one copy is evaluated, so the cost
 // stays that of the original texture about 90 percent of the time.
 const float TW=80.,FW=4.;
 float omr=u_rotation*.3/pow(max(r,1.1),1.5);
 float uA=mod(u_time,TW),uB=mod(u_time+.5*TW,TW);
 float wA=smoothstep(.5*FW,1.5*FW,min(uA,TW-uA));
 float phA=a-omr*uA+1.7*floor(u_time/TW),phB=a-omr*uB+1.7*floor(u_time/TW+.5)+.9;
 // Stretch existing noise along the orbit without extra noise samples.
 float detail=u_disk_detail>.5?4.:1.;
 float originalR=r;
 r*=detail;
 float n,s3ph;
 if(wA>.999){
  n=mix(fbm(vec2(r*2.7+cos(phA)*5.,sin(phA)*5.+u_time*.08+noiseSeed()*.01)),fbm(vec2(r*9.+cos(phA)*13.,sin(phA)*13.-u_time*.17)),.42);
  s3ph=sin(phA*3.);
 }else{
  float nA=mix(fbm(vec2(r*2.7+cos(phA)*5.,sin(phA)*5.+u_time*.08+noiseSeed()*.01)),fbm(vec2(r*9.+cos(phA)*13.,sin(phA)*13.-u_time*.17)),.42);
  float nB=mix(fbm(vec2(r*2.7+cos(phB)*5.,sin(phB)*5.+u_time*.08+noiseSeed()*.01+3.1)),fbm(vec2(r*9.+cos(phB)*13.,sin(phB)*13.-u_time*.17+5.3)),.42);
  n=.5+(wA*nA+(1.-wA)*nB-.5)/sqrt(wA*wA+(1.-wA)*(1.-wA));   // variance-preserving blend
  s3ph=wA*sin(phA*3.)+(1.-wA)*sin(phB*3.);
 }
 r=originalR;
 bool photoDisk=u_pal_a>1.5&&u_pal_a<2.5;
 float innerWidth=max(.24,1.6*g_fw*length(g_cam));
 float inner=photoDisk?smoothstep(u_isco,u_isco+innerWidth,r):smoothstep(u_isco,u_isco+.7,r);
 float edge=inner*(1.-smoothstep(g_dout-1.5*g_soft,g_dout+.5*g_soft,r));
 // Structure that moves legibly: a few hot spots riding Keplerian orbits
 // (angular speed ~ r^-1.5, the same flow as the texture, so they shear with
 // it) and a two-armed spiral density wave turning at one pattern speed. The
 // angle enters only through sin/cos, so there is no seam at a = +-PI.
 float spots=0.;
 if(u_structure>0.){
  for(int i=0;i<4;i++){
   float fi=float(i);
   float ri=u_isco+1.3+fi*1.9*(g_dout-u_isco)/9.;
   float phi=fract(sin(fi*12.9898+u_seed*.001)*43758.5453)*6.2831853+u_rotation*u_time*.3/pow(max(ri,1.1),1.5);
   float ch=2.*ri*sin(.5*(a-phi));             // chord length along the orbit
   float dr=r-ri,w=.35+.09*ri;
   spots+=exp(-(dr*dr+ch*ch)/(w*w))*(.7+.3*sin(u_time*.4+fi*2.1));
  }
  float wave=.5+.5*cos(2.*a-u_rotation*u_time*.3/pow(6.,1.5)*2.-3.2*log(max(r,1.)));
  spots=u_structure*(1.1*spots+.35*(wave-.5));
 }
 float sourceFlux=u_temperature_profile>.5?pageThorneFlux(r):1.;
 float heat=clamp((u_temperature_profile>.5?pow(sourceFlux,.25):pow(3./max(r,u_isco),.75))*u_temperature,0.,1.);
 float beta=sqrt(.5/max(r-1.,2.));
 vec3 velocity=normalize(cross(diskN,normalize(p)))*(u_rotation<0.?-beta:beta);
 float dop=sqrt(1.-beta*beta)/max(1.-dot(velocity,g_photon),.001);
 float grav=sqrt(max(1.-1./max(r,1.001),.02)/g_observer);
 float shift=dop*grav;
 // Oil-slick iridescence: hue shifts with orbital angle and Doppler term so
 // a single frame carries several bands. Slow radius offset avoids the hue
 // fighting the temperature ramp.
 // NOTE: `a` is atan(p.y,p.x) and therefore JUMPS from +PI to -PI along one
 // radial line. Driving hue LINEARLY from it (previously (a/(2.*PI))*.18)
 // stepped bandHue by a full 0.18 across that seam, which rendered as a hard
 // straight colour boundary splitting the disk - observed live on a T2 MacBook Pro as a
 // teal/gold edge down the middle. Use a periodic function of the angle
 // instead: sin/cos are continuous across the wrap and keep comparable
 // amplitude (+/-.09 here vs the old 0.18 peak-to-peak), so the disk gets the
 // same oil-slick banding with no discontinuity.
 float dopColor=mix(1.,dop,u_doppler_shift*dopplerStrength());
 float bandHue=.09*sin(a)+.045*sin(2.*a)+0.06*s3ph+0.04*(dopColor-.35)/1.45;
 float radiusHue=(r-3.)*.012;
 float paletteT=clamp(heat*dopColor*grav,0.,1.)+bandHue+radiusHue;
 // A real disk-space hot sector also appears in the lensed disk images.
 // Hot sector. Previously cos^4 at 0.65 amplitude, which rotated as a hard
 // narrow lobe and read as a searchlight sweeping the disk (reported on
 // an Intel + NVIDIA laptop 2026-09-28, visible in ALL colour modes). Widened to cos^2 and
 // cut to 0.22 so it is a broad brightening rather than a spotlight.
 float sector=max(cos(a-(.22*u_time+.00001*u_seed)),0.);
 sector*=sector;
 // The physical colour modes derive their asymmetry from Doppler beaming
 // (dop) which is already applied; an artistic hot sector on top of that is
 // double-counting, so it is stylised-only.
 float hm=clamp(heat,0.,1.);
 vec3 cA=palTint(u_pal_a,hm,dop,grav,r,a,paletteT,sector,drama);
 if(u_pal_mix>.001){
  vec3 cB=palTint(u_pal_b,hm,dop,grav,r,a,paletteT,sector,drama);
  cA=mixOk(cA,cB,u_pal_mix);
 }
 // Chromatic shifts must not smuggle another intensity law into g^4.
 // Preserve the source palette's emitted bolometric luminance while changing
 // its observed chromaticity. Both palette endpoints use the same rule.
 float emittedT=clamp(heat,0.,1.)+bandHue-.04*(dopColor-1.)/1.45+radiusHue;
 vec3 emittedTint=palTint(u_pal_a,hm,1.,1.,r,a,emittedT,sector,drama);
 if(u_pal_mix>.001)emittedTint=mixOk(emittedTint,palTint(u_pal_b,hm,1.,1.,r,a,emittedT,sector,drama),u_pal_mix);
 const vec3 bolometricWeights=vec3(.2126,.7152,.0722);
 float emittedLuma=u_temperature_profile>.5?1.:dot(emittedTint,bolometricWeights),observedLuma=dot(cA,bolometricWeights);
 cA=observedLuma>1e-8?cA*(emittedLuma/observedLuma):vec3(emittedLuma);
 float turbulent=1.;
 if(u_turbulence>0.){
  // Bounded, advected domain-warped noise; procedural variability, not fluid dynamics.
  vec2 q=vec2(r*.73+cos(a)*2.1,sin(a)*2.1);
  vec2 qv=q*g_diskFreq;
  vec2 warp=vec2(fbm(qv+vec2(u_time*.037,noiseSeed()*.013)),fbm(qv.yx+vec2(-u_time*.029,noiseSeed()*.021)))-.5;
  float n0=fbm(qv+2.2*warp+vec2(u_time*.071,0.));
  float n1=fbm(qv*2.03+3.4*warp+vec2(0.,-u_time*.053));
  float n2=fbm(qv*4.11+5.1*warp+vec2(u_time*.031,u_time*.019));
  float variation=clamp((.5*n0+.32*n1+.18*n2-.5)*2.4,-.65,.65);
  turbulent=clamp(1.+u_turbulence*variation,.35,1.65);
 }
 float streak=1.;
 if(u_pal_a>1.5&&u_pal_a<2.5)streak=.86+.28*n+.055*sin(34.*a+3.2*r-.09*u_time*u_rotation);
 float material=1.;
 if(u_ejecta>0.&&u_ejecta_rate>0.){
  float stream=exp(-18.*pow(sin(3.*a+2.*sqrt(r)+u_time*u_ejecta_rate*.3),2.));
  float grazing=1.-smoothstep(.06,.3,abs(dot(diskN,g_photon)));
  float heatUp=exp(-max(r-3.,0.)*.22);
  material=(1.+.35*u_ejecta*stream*heatUp)*
           (1.-.35*min(u_ejecta,1.5)*grazing*stream*(1.-heatUp));
 }
 return sourceFlux*transportG4(dop,max(1.-1./max(r,1.001),.02))*cA*edge*max(.32+1.2*g_diskTurb*n+spots*(.6+.8*n),.05)*streak*u_density*u_disk_emission*turbulent*material;
}
// Convert a world-space sample to the local Schwarzschild-radius units used
// by flow_sample. Keep this shared by both integrators.
vec3 flow_local_position(vec3 world,vec3 center,float rs){
 return (world-center)/max(rs,1e-6);
}
// Optional volumetric flows are sampled only in the rich integrator. The
// legacy disk path remains the plane-crossing code above, unchanged.
vec3 flow_sample(vec3 p,float rs,float dt,float drama){
 if(u_flow<.5)return vec3(0.);
 float r=length(p);
 float isco=max(u_isco,1e-4);
 if(r<isco||r>g_dout)return vec3(0.);
 if(u_flow>2.5){
  // Quasi-spherical emission follows an inverse-square radial profile.
  float radial=1./max(r*r,1.);
  radial=pow(radial,mix(1.5,.5,u_flow_extent)); // extent .5 preserves inverse square
  return disk_color(vec3(r,0.,0.),vec3(0.,0.,1.),drama)*radial*dt*2.2;
 }
 float h=max(.12, u_flow_extent* (u_flow>1.5 ? .9 : .48) * r);
 float vertical=exp(-p.z*p.z/(h*h));
 float radial=pow(3./max(r,isco),u_flow>1.5?.35:1.15);
 float dim=(u_flow>1.5?.20:.60);
 vec3 emitted=disk_color(p,vec3(0.,0.,1.),drama)*vertical*radial*dim*dt*2.0;
 if(u_flow>1.5){
  // A RIAF is intentionally less efficiently radiating and less strongly
  // Doppler-brightened on the approaching (+y) side than the thin disk.
  float approach=clamp(p.y/max(length(p.xy),.001),-1.,1.);
  emitted*=1.-.30*max(approach,0.);
 }
 return emitted;
}
// Jet picks up the palette so it tracks the rest of the scene instead of a
// fixed blue. Sampled at a hot temperature so it sits at the bright stop.
vec3 jet_tint(){
 Stop s0,s1,s2,s3;paletteStops(u_palette,s0,s1,s2,s3);
 Stop hot=stopAHue(s2,s3,.85);
 float active_h=u_palette_phase+u_time*u_palette_rate*1.5;
 hot.h=fract(hot.h+active_h);
 vec3 c=hsl2rgb(vec3(hot.h,.9,.58));
 // Physical colour modes: relativistic jets are non-thermal synchrotron
 // emission, cool blue-white, not part of the blackbody disk palette.
 if(u_pal_a>8.5)return srgbLin(vec3(.133,.827,.933))*1.3;
 if(u_pal_a>7.5)return vec3(.35,.95,1.);
 if(u_pal_a>6.5)return hsl2rgb(vec3(fract(u_time*.05+u_palette_phase),.95,.6));
 return (u_pal_a<.5)?c:(u_pal_a<3.5&&u_pal_a>2.5)?vec3(1.):(u_pal_a>5.5)?vec3(1.,.72,.42):vec3(.55,.72,1.);
}
// Optically thin phenomenological synchrotron outflow, units rs and rs/c.
// beta=.65 (Gamma=1.316); knot pattern travels with the same bulk speed.
// Gaussian spine + faint sheath, parabolic collimation becoming conical.
const float JET_BETA=.65;
const float JET_EMISSIVITY=.12;
const float JET_KNOT_CONTRAST=1.8;
const float JET_HELIX_AMPLITUDE=.10;
const float JET_FILAMENT_AMPLITUDE=.12;
const float JET_COLLIMATION=8.;
const float JET_BASE=1.5;
const float JET_KNOT_SPACING=5.;
float jet_width(float h){
 float opening=tan(radians(u_jet_opening));
 return .16+opening*sqrt(h*(h+JET_COLLIMATION));
}
vec3 jet_emission(vec3 p,vec3 axis,vec3 photon){
 float signedHeight=dot(p,axis),h=abs(signedHeight),r=length(p);
 if(h<JET_BASE||r<=1.||h>4.*u_jet_len)return vec3(0.);
 vec3 e=normalize(cross(axis,abs(axis.z)<.9?vec3(0,0,1):vec3(0,1,0)));
 vec3 f=cross(axis,e);
 float width=jet_width(h);
 float phase=h*.45-u_time*.18+mod(u_seed,1021.)*.01;
 vec2 q=vec2(dot(p,e),dot(p,f))/width-JET_HELIX_AMPLITUDE*vec2(cos(phase),sin(phase));
 float rho=length(q),spine=exp(-3.*rho*rho);
 float sheath=.16*exp(-12.*(rho-.85)*(rho-.85));
 float advected=h-JET_BETA*u_time;
 float knotPhase=6.2831853*(advected/JET_KNOT_SPACING+mod(u_seed,997.)/997.);
 float knots=1.+JET_KNOT_CONTRAST*exp(-10.*(1.-cos(knotPhase)))*exp(-rho*rho);
 float filaments=1.+JET_FILAMENT_AMPLITUDE*sin(q.x*9.+phase)*sin(q.y*7.-phase*.7);
 float fade=smoothstep(JET_BASE,4.,h)*exp(-h/max(u_jet_len,.01))/(1.+h*.12);
 fade*=1.-smoothstep(3.*u_jet_len,4.*u_jet_len,h);
 vec3 velocity=axis*(signedHeight<0.?-JET_BETA:JET_BETA);
 float doppler=sqrt(1.-JET_BETA*JET_BETA)/max(1.-dot(velocity,photon),.001);
 float asymmetry=mix(1.,signedHeight>=0.?1.5:.5,u_jet_asymmetry);
 vec3 tint=mix(jet_tint(),vec3(1.),.8*spine*exp(-h/max(u_jet_len,.01)));
 // Sparse launch events with a finite ballistic lifetime. The monotone
 // trajectory h=base+v0*age-a*age^2/2 is inverted to find ONE nearest
 // launch, so particle count does not add a loop to the ray quadrature.
 // Acceleration is an artistic constant over this short outflow segment;
 // particles fade before their turning point (not a GR orbit integrator).
 vec3 base=JET_EMISSIVITY*tint*(spine+sheath)*knots*filaments*fade*asymmetry*
           transportG4(doppler,1.-1./r);
 if(u_ejecta<=0.||u_ejecta_rate<=0.)return base;
 const float launchSpeed=.8, deceleration=.003, cadence=8., lifetime=96.;
 float travel=(launchSpeed-sqrt(max(launchSpeed*launchSpeed-
              2.*deceleration*(h-JET_BASE),.0001)))/deceleration;
 float time=u_time*u_ejecta_rate;
 float event=floor((time-travel)/cadence+.5);
 float age=time-event*cadence;
 float alive=smoothstep(0.,4.,age)*(1.-smoothstep(72.,lifetime,age));
 float height=JET_BASE+launchSpeed*age-.5*deceleration*age*age;
 float speed=max(0.,launchSpeed-deceleration*age);
 float random=skyHash(vec3(mod(event,65521.),mod(u_seed,8191.),signedHeight<0.?7.:3.));
 // A compact clump with finite support is zero at event-cell boundaries.
 // Its transverse offset expands with the existing jet opening angle.
 vec2 offset=q-vec2(random-.5,fract(random*17.)-.5)*1.4;
 float axial=(h-height)/1.1;
 float clump=max(0.,1.-dot(offset,offset)*5.-axial*axial);
 clump*=clump*alive/(1.+.025*max(age,0.));
 // Sparse support: empty samples need no second Doppler/transport evaluation.
 if(clump<=0.)return base;
 vec3 ejectVelocity=axis*(signedHeight<0.?-speed:speed);
 float ed=sqrt(max(1.-speed*speed,.01))/max(1.-dot(ejectVelocity,photon),.001);
 float shift=clamp(.15*(ed-1.),-.2,.35);
 vec3 ejectTint=jet_tint()*vec3(1.-shift,1.,1.+shift);
 return base+JET_EMISSIVITY*ejectTint*clump*u_ejecta*(1.+u_ejecta_burst)*
             fade*asymmetry*transportG4(ed,1.-1./r);
}
// Corona colour: the thermal bremsstrahlung peak of a hot corona sits at the
// hard X-ray edge and lands at the short end of the visible band, so
// u_corona_temp shifts a blue-white base toward the cool end of the blackbody
// locus (the same curve the faithful disk colours ride). Independent of the
// disk temperature option: the corona is a separate component.
vec3 corona_color(float r){
 float k=mix(9500.,2400.,.8*(1.-clamp(.5*u_corona_temp,0.,1.)));
 return mix(blackbodyRGB(k),vec3(1.),.35)*(1.+.15*smoothstep(1.2,3.,u_corona_temp));
}
// Corona emission at a local (r_s units) point p inside a bounded step dt.
// Optically thin: brightness is proportional to u_corona and to the path
// length, and it falls off radially (hot gas concentrated at the ISCO) with
// a vertical Gaussian so the halo extends above and below the disk plane.
// The caller supplies the local frame: world->hole position, the hole's r_s.
// The caller must gate on if(u_corona>0.) so the default costs nothing.
vec3 corona_sample(vec3 p,float dt){
 float isco=max(u_isco,1e-4);
 float r=length(p.xy);
 float rmax=u_isco+u_corona_extent*u_isco;   // ISCO-unit extent
 if(r<isco||r>rmax)return vec3(0.);
 float radial=exp(-max(r-isco,0.)/max(u_corona_extent*u_isco,1e-3));
 float h=max(.35,u_corona_extent*u_isco*.4);
 float vertical=exp(-p.z*p.z/(h*h));
 float radial2=1./max(r*r,1.);
 return corona_color(r)*u_corona*radial*radial2*vertical*dt*1.8;
}
// Jet colour. u_jet_color is a float id: 0 auto / 1 palette (both track the
// disk palette via jet_tint()), 2 blue, 3 white, 4 orange, 5 cyan (fixed,
// non-thermal, and CONSISTENT across palettes). The fixed colours are
// multiplied by 1.3 so they sit at the same linear radiance as the palette
// branch instead of reading as a dim, desaturated smear.
vec3 jet_color(){
 float id=floor(u_jet_color+.5);
 if(id<1.5)return jet_tint();
 if(id<2.5)return srgbLin(vec3(.20,.55,1.0))*1.3;
 if(id<3.5)return vec3(.92,.96,1.0);
 if(id<4.5)return srgbLin(vec3(1.0,.55,.18))*1.3;
 return srgbLin(vec3(.133,.827,.933))*1.3;
}
// Two thin collimated beams along +-axis (the disk normal), rendered from the
// ray's closest approach to the axis line (unlensed straight-ray approximation).
// This replaces a screen-fixed cone test (smoothstep on |dot(ray,axis)|) that
// painted a large ellipse wherever the view direction was within ~13 degrees of
// the axis, textured by screen-space noise: the "searchlight with large dots"
// artifact reported on a test machine (an Intel + NVIDIA laptop) 2026-09-28 in ALL
// colour modes.
//
// The two poles are evaluated EXPLICITLY and summed, each with its own signed
// height and its own Doppler beaming factor, so the twin jets read as
// back-to-back lobes with the approaching one brighter (both always present).
// Pure: no side effects, no dependence on main()'s state.
vec3 jet_lobes(vec3 cam,vec3 ray,vec3 axis0){
 // slow precession of the jet around the disk normal (option-controlled now:
 // u_jet_precess==0 keeps the axis fixed, 1 is the ~5-degree wobble)
 vec3 e1=normalize(cross(axis0,abs(axis0.x)<.9?vec3(1.,0.,0.):vec3(0.,1.,0.))),e2=cross(axis0,e1);
 vec3 axis=normalize(axis0+.09*u_jet_precess*(cos(u_time*.045)*e1+sin(u_time*.045)*e2));
 vec3 uc=normalize(-cam);              // direction from the hole to the camera
 vec3 col=jet_color();
 float b=dot(ray,axis);
 float den=1.-b*b;
 if(den<1e-4)return vec3(0.);
 float pole=smoothstep(.01,.18,den);   // gentler floor: a view within ~15 deg of the axis still shows both lobes
 float d=dot(ray,cam),e=dot(axis,cam);
 float t=(b*e-d)/den;                  // distance along the ray to closest approach
 if(t<0.)return vec3(0.);
 float sa=(e-b*d)/den;                 // signed height along the jet axis at closest approach
 float h=abs(sa);
 if(h<3.2||h>max(60.,u_jet_len*4.))return vec3(0.);
 vec3 q=cam+t*ray-sa*axis;
 float w=max(.22+.07*h,tan(radians(u_jet_opening))*h)*u_jet_width; // configured conical half-angle x width multiplier
 w*=(1.0+0.6*(1.0-pole));                  // widen slightly near pole-on views
 vec3 acc=vec3(0.);
 // Evaluate each pole at the same closest-approach geometry (same t, q, h).
 // Only the SIGN of the lobe direction differs, which flips the beaming term
 // and the artistic pole bias (the two lobes point opposite ways), so the two
 // lobes are not mirror-locked.
 for(int s=-1;s<=1;s+=2){
  float sf=float(s);
  float toward=dot(normalize(sf*axis),uc);  // +1 = this lobe points at the camera
  float beam=clamp(1.0+u_jet_beaming*0.55*toward,0.30,1.90);
  float prof=exp(-dot(q,q)/(w*w));
  if(u_enh>.5){
   // enhanced: a spine inside a wider, fainter sheath, so a jet seen from
   // the side has a cross-section instead of reading as a flat bar
   float w2=w*2.6;
   prof=.75*prof+.35*exp(-dot(q,q)/(w2*w2));
  }
  // Knots streaming outward, smooth in beam-space (no screen-space blocks).
  // h is unsigned distance along the axis (abs(sa)), so the phase uses h alone:
  // dh/dt = +1.6/0.55 = +2.909 world units/s on BOTH poles, i.e. every knot
  // marches away from the hole. The sign(sa) term that used to be here flipped
  // the phase on the negative pole (sa<0), making dh/dt negative there -- one
  // jet ran inward while the other ran outward, so both appeared to travel
  // the same way on screen.
  float knots=.55+.45*noise(vec2(h*.55-u_time*1.6,atan(q.y,q.x)*.0+noiseSeed()*.01));
  float fade=smoothstep(3.2,5.5,h)*exp(-h/u_jet_len);
  float near=smoothstep(1.,7.,t);           // no hard cut where the closest approach passes the camera
  float poleBrightness=mix(1.,sf>0.?1.5:.5,u_jet_asymmetry);
  acc+=col*prof*knots*fade*pole*near*beam*poleBrightness;
 }
 return acc;
}
// Legacy name kept for the traceMulti light path, which resolves to the two-
// lobe evaluator now.
vec3 jet_glow(vec3 cam,vec3 ray,vec3 axis0){return jet_lobes(cam,ray,axis0);}
// Zero velocity and acceleration at each envelope endpoint.
float ease5(float a,float b,float x){float t=clamp((x-a)/(b-a),0.,1.);return t*t*t*(t*(t*6.-15.)+10.);}


// ---- scene extras (presets): dusty torus, companion star and gas stream ----
// Straight-ray approximations (no lensing): artistic, not geodesic.
// Dusty torus: an elliptical-section ring around the disk axis; returns
// (emission rgb, optical depth in .w) accumulated along the ray.
vec4 torusAlong(vec3 cam,vec3 ray,vec3 axis){
 float tmax=length(cam)*2.+u_torus_r*2.;
 float dt=tmax/20.,tau=0.;vec3 em=vec3(0.);
 for(int i=0;i<20;i++){
  vec3 p=cam+ray*(dt*(float(i)+.5));
  float z=dot(p,axis);float rho=length(p-axis*z);
  float dr=(rho-u_torus_r)/(.17*u_torus_r),dz=z/(.13*u_torus_r);
  float d=exp(-(dr*dr+dz*dz));
  tau+=d*dt*.06;
  em+=d*dt*.032*vec3(.62,.30,.16)*(.6+.4*exp(-rho/(u_torus_r*.9)));
 }
 return vec4(em,tau);
}
// ---- Companion star and its Roche-lobe-overflow stream (microquasar look) ----
// Both are traced along the SAME bent ray the disk uses (they are tested on each
// integration step of the geodesic loop), so the star is lensed like everything
// else: it smears into arcs and forms a secondary image near the photon ring
// when it is behind the hole, is hidden by the hole, and is dimmed by the disk
// it is seen through. Cost is paid only when u_comp > 0. Everything is a pure
// function of u_time and u_seed: no state, no per-frame allocation.
//   star   : hot blue supergiant, a prolate ellipsoid stretched toward the hole
//            (tidal elongation), limb darkened, gravity darkened at the inner
//            Lagrange point, with a soft glow in the scene's bloom colour.
//   stream : a continuous tube that leaves the star's inner Lagrange point, is
//            swept ahead of the orbit as it falls inward (angular momentum is
//            conserved, so it winds forward faster than the star moves), tapers,
//            and ends in a hot impact region at the disk edge.
vec3 g_cEx=vec3(1.,0.,0.),g_cEy=vec3(0.,1.,0.),g_cEz=vec3(0.,0.,1.),g_cC=vec3(0.),g_cA=vec3(1.,0.,0.);
vec3 g_cStar=vec3(0.),g_cMid=vec3(0.),g_cGas=vec3(0.),g_cHot=vec3(0.),g_cGlow=vec3(0.),g_cP1=vec3(0.);
float g_cRs=1.,g_cR0=1.,g_cR1=1.,g_cTh=0.,g_cSig=1.,g_cPix=0.,g_cFade=1.,g_cRmin=0.,g_cZmax=1.;
const float COMP_LEAD=1.5;       // how far ahead of the star the stream lands on the disk edge (rad)
float g_cElong=1.14;             // semi-axis of the star toward the hole / its radius (per launch)
// Inverse of toDiskLocal: disk-local vector -> world.
vec3 fromDiskLocal(vec3 q,vec3 n){
 vec3 cz=cross(n,vec3(0.,0.,1.));
 if(length(cz)<1e-5)return n.z<0.?vec3(q.x,-q.y,-q.z):q;
 vec3 ax=normalize(cz);
 float ang=acos(clamp(n.z,-1.,1.)),c=cos(ang),s=sin(ang);
 return q*c-cross(ax,q)*s+ax*dot(ax,q)*(1.-c);
}
// The companion lives in the disk plane, so it is built there from the disk
// frame. Basis vectors must be mapped FROM disk space into world space;
// the inverse transform would reflect the tilt and detach the stream.
void compInit(vec3 cam,vec3 diskN){
 float R=u_disk_out*1.7;
 g_cEx=fromDiskLocal(vec3(1.,0.,0.),diskN);g_cEy=fromDiskLocal(vec3(0.,1.,0.),diskN);g_cEz=cross(g_cEx,g_cEy);
 g_cSig=u_rotation<0.?-1.:1.;                         // orbits the way the disk turns
 float ph0=6.2831853*fract(sin(mod(u_seed,6283.185)*12.9898)*43758.5453);
 g_cTh=ph0+g_cSig*u_time*.035;
 // Per-launch star: radius and colour temperature both vary, and the tidal
 // stretch is stronger than the old fixed 1.14 so the star reads as being
 // pulled apart rather than as a slightly squashed ball.
 float hSz=fract(sin(mod(u_seed,7919.)*45.233)*19117.31);
 float hTk=fract(sin(mod(u_seed,4423.)*78.233)*37139.73);
 float hEl=fract(sin(mod(u_seed,6151.)*31.717)*21499.37);
 g_cRs=R*(.085+.105*hSz);                    // 0.65x .. 1.8x of the old .13
 g_cElong=1.22+.55*hEl;                      // 1.22 .. 1.77 toward the hole
 float starT=3100.+21400.*hTk;               // 3,100 K .. 24,500 K
 g_cC=R*(cos(g_cTh)*g_cEx+sin(g_cTh)*g_cEy);
 g_cA=-normalize(g_cC);
 g_cR0=R-g_cRs*1.0;                                   // stream leaves the star's near side
 g_cR1=u_disk_out*.97;                                // and lands on the disk edge
 float ph1=g_cTh+g_cSig*(COMP_LEAD+.14);
 g_cP1=g_cR1*(cos(ph1)*g_cEx+sin(ph1)*g_cEy);
 g_cRmin=g_cR1-g_cRs*1.3;g_cZmax=g_cRs*1.5;
 g_cPix=g_fw*max(length(cam-g_cC),1.);
 g_cFade=smoothstep(.5,3.,length(cam-g_cC)/g_cRs)*clamp(u_comp,0.,1.);   // option strength; fades out if a camera path passes close
 // colours: the star stays a hot blue-white supergiant tinted by the active palette;
 // the gas runs from the star's colour to the palette's hot colour and is kept saturated.
 vec3 bluish=srgbLin(vec3(.56,.74,1.));
 if(u_pal_a>8.5){
  vec3 cy=srgbLin(vec3(.133,.827,.933)),mg=srgbLin(vec3(.878,.188,.620));
  g_cStar=mixOk(blackbodyRGB(starT),cy,.35);g_cGas=mg;
  g_cHot=satBoost(mixOk(mg,srgbLin(vec3(1.,.55,.80)),.35),1.2);
 }else{
  // the gas takes the colour of the disk it falls onto: sample that palette's own disk
  // colour (receding side, mid heat) and keep only its hue and saturation
  vec3 warm=palTint(u_pal_a,.55,1.,.85,u_disk_out*.75,-.6,.55,0.,0.);
  vec3 hotc=palTint(u_pal_a,1.,1.,.85,u_disk_out*.75,-.6,.9,0.,0.);
  if(u_pal_mix>.001){warm=mixOk(warm,palTint(u_pal_b,.55,1.,.85,u_disk_out*.75,-.6,.55,0.,0.),u_pal_mix);hotc=mixOk(hotc,palTint(u_pal_b,1.,1.,.85,u_disk_out*.75,-.6,.9,0.,0.),u_pal_mix);}
  // Temperature dominates; a little palette mix keeps it in the scene, but not
  // so much that every star comes out the same white.
  g_cStar=mixOk(blackbodyRGB(starT),jet_tint(),.16);
  g_cGas=satBoost(warm/max(max(warm.r,max(warm.g,warm.b)),1e-3)*.85,(u_pal_a>2.5&&u_pal_a<3.5)?1.:2.);
  g_cHot=satBoost(hotc/max(max(hotc.r,max(hotc.g,hotc.b)),1e-3)*1.1,1.25);
 }
 g_cMid=mixOk(g_cStar,g_cGas,u_pal_a>8.5?.5:.7);
 g_cGlow=g_cStar*(.10+.22*min(u_bloom,1.2));
}
// One integration step a->b of the bent ray. Adds the star's glow, its limb-darkened
// surface and the stream, attenuated by what the ray already passed (disk, stream).
// Returns true when the star blocks the ray.
bool compSeg(vec3 a,vec3 b,inout vec3 color,inout float trans){
 vec3 sg=b-a;float sl=length(sg);
 if(sl<1e-5)return false;
 // --- star: ellipsoid -> unit sphere (stretch removed along the hole axis)
 vec3 o=(a-g_cC)/g_cRs,d=sg/g_cRs;
 o+=g_cA*dot(o,g_cA)*(1./g_cElong-1.);d+=g_cA*dot(d,g_cA)*(1./g_cElong-1.);
 float dd=dot(d,d),bq=dot(o,d);
 float h=clamp(-bq/dd,0.,1.);
 vec3 q=o+d*h;float dq=length(q);
 if(dq<4.5){
  color+=trans*g_cFade*g_cGlow*exp(-max(dq-1.,0.)*3.)*min(sl/g_cRs,2.)*.5;
  float pw=g_cPix/g_cRs;
  float cov=1.-smoothstep(1.-pw,1.+pw,dq);
  if(cov>.002){
   vec3 n=q/max(dq,1e-4);
   if(dq<1.){float t=clamp((-bq-sqrt(max(bq*bq-dd*(dot(o,o)-1.),0.)))/dd,0.,1.);n=normalize(o+d*t);}
   float mu=clamp(dot(n,-d/sqrt(dd)),0.,1.);
   float limb=.06+.94*pow(mu,1.1);                              // strong limb darkening (display gamma flattens it)
   float nose=1.-.35*smoothstep(.55,1.,dot(n,g_cA));             // gravity darkening toward L1
   vec3 surf=(g_cStar*2.1+vec3(.30,.34,.40)*mu*mu*mu)*limb*nose;  // saturated limb, blue-white core
   color+=trans*g_cFade*cov*surf;
   trans*=1.-cov*g_cFade;
   if(cov>.995&&g_cFade>.99){trans=0.;return true;}
  }
 }
 // --- stream: only when the segment is near the orbital plane and inside the shell
 float za=dot(a,g_cEz),zb=dot(b,g_cEz);
 float zmin=(za*zb<0.)?0.:min(abs(za),abs(zb));
 if(zmin<g_cZmax){
  vec3 m=.5*(a+b);
  float rm=length(m-g_cEz*dot(m,g_cEz));
  if(rm-.5*sl<g_cR0+g_cRs*.2&&rm+.5*sl>g_cRmin){
   float dl=sl/6.;                               // 6 samples per step: small beads alias at 4
   float box=dl*dl*.1667;                        // box prefilter, so a thin tube never falls between samples
   float r01=g_cR0-g_cR1;
   for(int j=0;j<6;j++){
    vec3 X=a+sg*((float(j)+.5)/6.);
    vec3 lp=vec3(dot(X,g_cEx),dot(X,g_cEy),dot(X,g_cEz));
    float r=length(lp.xy);
    float s=(g_cR0-r)/r01,sc=clamp(s,0.,1.);
    float edge=smoothstep(-.02,.07,s)*(1.-smoothstep(.97,1.06,s));
    // Spaghettification reads as a STRING OF SMALL CLUMPS, not one smooth tube
    // (operator, 2026-10-29: "needs to be more particles, smaller objects").
    // 34 beads along the arc, each sharper than the gap between them, each with
    // its own size and brightness, and thinner across the flow than along it so
    // the debris looks stretched rather than like a rope.
    float nb=34.;
    float bp=sc*nb,bi=floor(bp),bf=fract(bp);
    float bead=pow(max(0.,1.-abs(2.*bf-1.)),2.2);
    float hb=fract(sin(bi*12.9898+u_seed*.017)*43758.5453);
    float beadGain=.55+.90*hb;
    float beadSize=.55+.60*hb;
    float w=g_cRs*mix(.17,.055,sc)*mix(1.,beadSize,.55);
    float we2=w*w+box;
    vec3 em=vec3(0.);float kab=0.;
    if(edge>.001){
     float ph=g_cTh+g_cSig*(COMP_LEAD*pow(sc,1.7)+.14*sc);
     float dph=g_cSig*(COMP_LEAD*1.7*pow(sc,.7)+.14)*(-1./r01);          // d(phase)/dr along the path
     vec2 u=lp.xy/max(r,1e-3);vec2 cv=vec2(cos(ph),sin(ph));
     float f=atan(u.y*cv.x-u.x*cv.y,dot(u,cv));
     float dperp=r*f/sqrt(1.+r*r*dph*dph);                                // distance to the path
     float dens=exp(-(dperp*dperp*2.2+lp.z*lp.z*1.6)/we2)*(w*w/we2)*edge*bead*beadGain;
     // Cool where it leaves the star, hot where it hits: the gradient runs the
     // whole length now (it used to flatten out at 0.72 and read as one colour).
     vec3 col=satBoost(mix(mix(g_cStar,g_cMid,smoothstep(0.,.18,sc)),g_cGas,smoothstep(.10,.45,sc)),1.35);
     em=col*dens*(.28+.90*pow(sc,1.3));
     kab=dens*.30;
    }
    // hot impact region where the stream meets the disk edge
    // (a flattened splash in the disk plane, longer along the orbit than across it)
    vec3 dp=X-g_cP1;
    vec3 rh=normalize(g_cP1),th=cross(g_cEz,rh)*g_cSig;
    float wr=g_cRs*.30,wt=g_cRs*.62,wz=g_cRs*.17;
    float er=wr*wr+box,et=wt*wt+box,ez=wz*wz+box;
    float hx=dot(dp,rh),hy=dot(dp,th),hz=dot(dp,g_cEz);
    float hd=exp(-(hx*hx/er+hy*hy/et+hz*hz/ez))*sqrt(wr*wr*wt*wt*wz*wz/(er*et*ez));
    em+=g_cHot*hd*1.6;
    color+=trans*g_cFade*em*dl;
    trans*=exp(-kab*dl*g_cFade);
   }
  }
 }
 return false;
}
// Sky/bloom constants per palette: x = nebula scale, base sky color, star tint,
// nebula tint, halo color, palette bloom strength, interior haze amount.
void palSky(float mode,out float neb,out vec3 base,out vec3 stint,out vec3 ntint,out vec3 halo,out float pbloom,out float haze){
 neb=1.;base=vec3(.002,.003,.007);stint=vec3(1.);ntint=vec3(1.);halo=vec3(1.);pbloom=0.;haze=0.;
 if(mode<2.5)return;
 if(mode<3.5){neb=0.;base=vec3(0.);stint=vec3(1.);halo=vec3(1.);pbloom=.15;return;}
 if(mode<4.5){neb=.30;base=vec3(.0035,.0055,.0135);stint=vec3(.85,.92,1.15);ntint=vec3(.55,.75,1.3);halo=vec3(1.,.62,.30);pbloom=.9;return;}
 if(mode>8.5){neb=.7;base=vec3(.0034,.0021,.0070);stint=vec3(.85,.95,1.15);ntint=vec3(1.1,.45,1.5);halo=vec3(.85,.25,.75);pbloom=.8;return;}
 if(mode>7.5){neb=.85;base=vec3(.006,.001,.012);stint=vec3(1.,.8,1.1);ntint=vec3(1.4,.45,1.2);halo=vec3(1.,.3,.8);pbloom=.9;return;}
 if(mode>6.5){neb=1.6;base=vec3(.004,.002,.008);stint=vec3(1.1,1.,1.2);ntint=vec3(1.3,1.1,1.5);halo=vec3(.75,.45,1.);pbloom=.8;return;}
 if(mode>5.5){neb=0.;base=vec3(0.);stint=vec3(.6,.55,.5);halo=vec3(1.,.55,.15);pbloom=.35;return;}
 neb=.55;base=vec3(.0016,.0042,.0100);stint=vec3(.9,1.,1.1);ntint=vec3(.35,.65,1.);halo=vec3(.55,.80,1.);pbloom=.7;haze=1.;
}
// ======================= scenes (compiled only when selected) =======================
#if BH_MULTI
// Orbital phase of the binary at emission time tr (scene seconds). Inspiral:
// phase = phi0 + w0 (8/5) t_c (1 - (1 - t/t_c)^(5/8)); a steady binary (no
// merge time) uses phase = phi0 + w0 (tr - now); after the merger the remnant
// rings at the ringdown frequency.
float gwPhase(float tr){
 if(u_gw2.y<0.)return u_gw.w+u_gw.y*(tr-u_gw2.x);
 if(tr<=0.)return u_gw.w+u_gw.y*tr;
 float tm=u_gw2.y,tc=u_gw.z;
 float te=min(tr,tm);
 float ph=u_gw.w+u_gw.y*1.6*tc*(1.-pow(max(1.-te/tc,1e-5),.625));
 return tr>tm?ph+.5*u_gw2.w*(tr-tm):ph;
}
// Strain amplitude envelope: ~1/a during the inspiral (normalized to 1 at the
// merger), exponential decay in the ringdown.
float gwAmp(float tr){
 if(u_gw2.y<0.)return 1.;
 float tm=u_gw2.y,tc=u_gw.z;
 if(tr>tm)return exp(-(tr-tm)/2.2);
 return .15+.85*pow(max(1.-tm/tc,1e-5)/max(1.-max(tr,0.)/tc,1e-5),.25);
}
// Quadrupole wave field in the orbital plane at X: two spiral arms moving
// outward at the wave speed (a retarded-time pattern cos 2(theta - phi(t - R/c))).
float gwField(vec2 X){
 float R=length(X);
 float tr=u_gw2.x-R/u_gw2.z;
 float th=atan(X.y,X.x);                          // enters only via cos(2 th): no seam
 float h=cos(2.*(th-gwPhase(tr)));
 return u_gw.x*gwAmp(tr)*h*smoothstep(2.,9.,R)/(1.+R*.045);
}
// Volume counterpart of shadePlane: preserve the scene's minidisk visibility
// and circumbinary/refilling ring in both quality modes.
vec3 sceneFlow(vec3 X,float dt,float drama){
 vec3 emitted=vec3(0.);
 if(u_fx.z>.001){
  for(int k=0;k<3;k++){
   float rs=u_holes[k].w;
   if(rs<=0.)continue;
   g_dout=u_scn.x;
   emitted+=u_fx.z*flow_sample(flow_local_position(X,u_holes[k].xyz,rs),rs,dt/rs,drama);
  }
 }
 if(u_scn.w>0.&&u_scn.y>0.){
  float k=3.2/u_scn.y;
  g_dout=u_scn.z*k;
  emitted+=u_scn.w*flow_sample(X*k,1.,dt*k,drama);
 }
 return emitted;
}
// Emission at a crossing of the orbital plane: each hole's minidisk (in that
// hole's own r_s units) and the circumbinary ring (rescaled so its inner edge
// sits where a disk's inner edge would).
vec3 shadePlane(vec3 X,float drama){
 vec3 c=vec3(0.);g_cov=0.;
 // Thick-flow modes emit along the ray in the rich integrator; do not also
 // draw the razor-thin legacy sheet at its plane crossings.
 if(u_flow>.5)return c;
 if(u_fx.z>.001){
  for(int i=0;i<3;i++){
   float rs=u_holes[i].w;
   if(rs<=0.)continue;
   vec3 rel=(X-u_holes[i].xyz)/rs;
   float r=length(rel.xy);
   if(r>u_isco-.2&&r<u_scn.x+1.){g_dout=u_scn.x;c+=u_fx.z*disk_color(rel,vec3(0.,0.,1.),drama);g_cov=max(g_cov,u_fx.z);}
  }
 }
 if(u_scn.w>0.){
  float R=length(X.xy);
  if(R>u_scn.y*.85&&R<u_scn.z*1.1){
   float k=3.2/u_scn.y;
   g_dout=u_scn.z*k;
   // The ring passes close to the camera on some paths; there it would fill
   // the view as a flat sheet, so it fades out near the camera.
   float nearCam=smoothstep(.25,.7,length(X-g_cam)/max(length(g_cam),1e-3))*smoothstep(.02,.09,g_dz);   // no 1-pixel line edge-on
   c+=u_scn.w*nearCam*disk_color(X*k,vec3(0.,0.,1.),drama);
   g_cov=nearCam;
  }
 }
 return c;
}
#if BH_LIGHT
// Light mode: thin-lens approximation. The ray is straight between holes and
// bends once at its closest approach to each hole (nearest first) by the
// Schwarzschild weak-field angle 2 r_s / b plus a steep term near the critical
// impact parameter, which draws the photon ring and the lensed far side of
// each disk. A capture inside the critical impact parameter ends the ray.
void traceMulti(vec3 cam,vec3 ray,float drama,inout vec3 color,inout float trans,out bool cap,out vec3 dOut,out vec3 oOut){
 vec3 x=cam,d=ray;cap=false;
 int used=0;
 for(int pass=0;pass<3;pass++){
  int best=-1;float bt=1e9;
  for(int k=0;k<3;k++){
   if(u_holes[k].w<=0.||((used>>k)&1)==1)continue;
   float t=dot(u_holes[k].xyz-x,d);
   if(t>0.&&t<bt){bt=t;best=k;}
  }
  if(best<0)break;
  used|=1<<best;
  vec3 c=u_holes[best].xyz;float rs=u_holes[best].w;
  vec3 P=x+d*bt;
  if(u_flow>.5){
   // Fixed four-sample volume estimate keeps the weak-GPU tier bounded.
   g_dout=u_scn.x;
   for(int j=0;j<4;j++){
    float f=(float(j)+.5)*.25;
    vec3 sampleP=mix(x,P,f);
    vec3 emitted=sceneFlow(sampleP,bt*.25,drama);
    color+=trans*emitted;
    trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
   }
  }
  if(u_corona>0.){
   // Light mode: one fixed-volume corona sample along the same straight
   // segment, bounded cost; occluded by the capture test (the ray never
   // reaches inside the shadow) and attenuated by the plane crossings.
   vec3 sampleP=x+d*(.5*bt);
   vec3 emitted=corona_sample(flow_local_position(sampleP,c,rs),bt/rs);
   color+=trans*emitted;
   trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
  }
  if(x.z*P.z<0.){g_dz=abs(d.z);vec3 X=mix(x,P,x.z/(x.z-P.z));color+=trans*shadePlane(X,drama);trans*=1.-.28*g_cov*u_disk_emission;}
  vec3 bv=P-c;float b=length(bv),bc=2.598*rs;
  // Photon ring: never thinner than about one pixel; when it is unresolved
  // its brightness scales with the pixel coverage instead of flickering.
  float wr=max(.12*rs,1.2*g_fw*length(P-g_cam));
  float ring=(b-bc)/wr;
  color+=trans*jet_tint()*.35*(.12*rs/wr)*exp(-ring*ring)*(.6+.4*u_bloom);
  if(b<bc){cap=true;x=P;break;}
  float al=u_lensing*(2.*rs/b+.62*exp(-(b-bc)/(.5*rs)));
  d=normalize(cos(al)*d-sin(al)*bv/b);
  x=P;
 }
 if(!cap&&u_flow>.5){
  float extent=max(u_scn.z*1.5,1.);
  for(int k=0;k<3;k++)extent=max(extent,length(u_holes[k].xyz)+u_holes[k].w*u_scn.x);
  float b=dot(x,d),disc=b*b-dot(x,x)+extent*extent;
  if(disc>0.){
   float lo=max(0.,-b-sqrt(disc)),hi=max(0.,-b+sqrt(disc));
   float dl=(hi-lo)*.25;
   for(int j=0;j<4;j++){
    vec3 emitted=sceneFlow(x+d*(lo+(float(j)+.5)*dl),dl,drama);
    color+=trans*emitted;
    trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
   }
  }
 }
 if(!cap&&x.z*d.z<0.){g_dz=abs(d.z);vec3 X=x-d*(x.z/d.z);color+=trans*shadePlane(X,drama);trans*=1.-.28*g_cov*u_disk_emission;}
 dOut=d;oOut=x;
}
#else
// Rich mode: every ray is integrated through the summed field of all holes.
// Per hole the photon acceleration is the Schwarzschild orbit equation in
// Cartesian form, a = -1.5 r_s |h|^2 x / r^5 (h = x cross v); superposing
// them is not general relativity, but it gives each hole its own shadow,
// photon ring and lensed disk, and lenses the neighbours' images.
void traceMulti(vec3 cam,vec3 ray,float drama,inout vec3 color,inout float trans,out bool cap,out vec3 dOut,out vec3 oOut){
 vec3 x=cam,v=ray;cap=false;
 float Rout=length(cam)+40.;
 int nx=0;   // plane crossings shaded: primary image, far-side arch, one secondary
 for(int i=0;i<int(u_max_steps);i++){
  vec3 acc=vec3(0.);float mr=1e9;
  for(int k=0;k<3;k++){
   float rs=u_holes[k].w;
   if(rs<=0.)continue;
   vec3 q=x-u_holes[k].xyz;float r2=dot(q,q),r=sqrt(r2);
   if(r<rs*1.01){cap=true;break;}
   vec3 h=cross(q,v);
   acc-=1.5*rs*dot(h,h)*q/(r2*r2*r);
   mr=min(mr,r-rs*.8);
  }
  if(cap)break;
  /* High-order photon rings: a ray that skims the photon sphere (r/rs ~ 1.5)
   * winds several times and returns images of the disk nested inside one another.
   * A step that is comfortable at r=10 jumps clean over whole rings there, so
   * shrink it near the photon sphere and let it recover outside. */
  float pr=1e9;
  for(int k=0;k<3;k++){
   float rs=u_holes[k].w;
   if(rs<=0.)continue;
   vec3 q=x-u_holes[k].xyz;
   pr=min(pr,abs(sqrt(dot(q,q))/rs-1.5));
  }
  float dt=clamp(.09*mr,.015,2.5)*mix(.38,1.,smoothstep(0.,.9,pr));
  vec3 xo=x;
  if(u_flow>.5){
   vec3 emitted=sceneFlow(x+v*(.5*dt),dt,drama);
   color+=trans*emitted;
   trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
  }
  if(u_corona>0.){
   // Corona sampled at the step midpoint in each hole's local frame, same
   // bounded dt as the flow: it transmits through the disk's attenuation.
   for(int k=0;k<3;k++){
    float rs=u_holes[k].w;
    if(rs<=0.)continue;
    vec3 mid=flow_local_position(x+v*(.5*dt),u_holes[k].xyz,rs);
    vec3 emitted=corona_sample(mid,dt/rs);
    color+=trans*emitted;
    trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
   }
  }
  v=normalize(v+u_lensing*acc*dt);
  x+=v*dt;
  if(xo.z*x.z<0.&&nx<3){nx++;g_dz=abs(v.z);vec3 X=mix(xo,x,xo.z/(xo.z-x.z));color+=trans*shadePlane(X,drama);trans*=1.-.28*g_cov*u_disk_emission;}
  if(dot(x,x)>Rout*Rout&&dot(x,v)>0.)break;
 }
 dOut=v;oOut=x;
}
#endif
#endif

#if BH_SCENE==3
// Tidal disruption. The star is a lensed sphere (tested against each ray
// segment of the integrator), stretched toward the hole. Its debris lies in
// the disk plane, so it is shaded at the plane crossings and is lensed too.
vec3 tdeStarColor(){
 // Operator, 2026-10-29: "the star is white, really should be variable color
 // and size". This used to be a fixed warm white (1,.86,.62), and tdeStar()
 // then applied a 3x gain that clipped every channel to 1.0 anyway -- the star
 // could not be anything BUT white. The temperature is now drawn per launch
 // and the star keeps its colour because the surface gain is ~1 instead of 3.
 float hT=fract(sin(mod(u_seed,5717.)*93.917)*31337.13);
 float starT=2900.+23000.*hT;                 // 2,900 K .. 25,900 K
 vec3 c=blackbodyRGB(starT);
 // Keep it saturated: normalise to the brightest channel so a red star stays
 // red instead of glowing out to white.
 c/=max(max(c.r,max(c.g,c.b)),1e-3);
 return mix(c,mix(c,palette(.85),.22),.35);
}
// Returns (radiance, 1 if hit) for the segment a..b.
vec4 tdeStar(vec3 a,vec3 b){
 // Size and tidal stretch vary per launch, so the same scene does not open on
 // the same ball every time.
 float hS=fract(sin(mod(u_seed,8317.)*57.113)*27193.71);
 float hE=fract(sin(mod(u_seed,9133.)*41.717)*19391.37);
 float R=u_tde.w*(.72+.62*hS);               // 0.72x .. 1.34x
 if(R<=.01)return vec4(0.);
 if(dot(u_tde.xyz,u_tde.xyz)<1e-6)return vec4(0.);
 vec3 C=u_tde.xyz,er=normalize(C);
 vec3 ab=b-a;float l2=max(dot(ab,ab),1e-6);
 float t=clamp(dot(C-a,ab)/l2,0.,1.);
 vec3 q=a+ab*t-C;
 float al=dot(q,er);vec3 pe=q-er*al;
 float stretch=u_tde3.x*(1.+0.45*hE);        // stronger tidal elongation
 float m=dot(pe,pe)/(R*R)+al*al/(R*R*max(stretch*stretch,1e-4));
 if(m>1.)return vec4(0.);
 float mu=sqrt(1.-m);
 // Gain 1.05, not 3.0: a hot core still reads bright, but the limb keeps the
 // star's own colour instead of clipping to white.
 return vec4(tdeStarColor()*(.40+1.05*mu)*(1.+0.55*pow(mu,6.)),1.);
}
// Debris stream density at plane point X. The bound debris is analytic: the
// orbital conic r_p (1+e)/(1 + e cos ang), wrapping forward around the hole
// and circularizing as e shrinks. The unbound debris is a 13-point polyline
// along the parabola behind the pericenter, spreading outward.
float tdeStream(vec2 X){
 float tau=u_tde2.x;
 if(tau<-1.5)return 0.;
 float rp=u_tde2.y,om=u_tde2.z,sg=u_tde2.w;
 float grow=clamp((tau+1.5)/3.,0.,1.);
 float e=mix(.95,.25,smoothstep(0.,50.,tau));
 float wrap=6.2831853*1.4*(1.-exp(-max(tau,0.)/14.))+.4*grow;
 float lead=grow*(1.2+min(max(tau,0.)*.05,1.5));
 float dens=0.;
 // Bound debris, analytic: the stream is the curve r(ang) = r_p (1+e)/(1 + e cos ang)
 // for ang in [0, wrap] (ang measured from the pericenter in the orbit's
 // sense). For this point, test the two windings its polar angle can be on;
 // the radial distance to the curve gives a smooth band with no polygon corners.
 float R=length(X);
 float ph=sg*(atan(X.y,X.x)-om);
 ph=ph-6.2831853*floor(ph/6.2831853);             // 0..2pi; enters r() only through cos
 for(int k=0;k<2;k++){
  float ang=ph+6.2831853*float(k);
  if(ang>wrap)break;
  float rs=rp*(1.+e)/(1.+e*cos(ang));
  rs=rs/(1.+rs/(14.*rp));                           // smooth cap on the apocenter (a hard min() made corners)
  // "needs to be more particles, smaller objects": the band is narrower and
  // broken into beads travelling along the debris curve.
  float w=(.30+.022*rs)*.48;
  float d=R-rs;
  float fadeTail=1.-smoothstep(wrap*.8,wrap,ang);  // the tail thins out
  // Two octaves of beads: a dense fine one that never lets the stream break,
  // and a coarse one that makes clumps of clumps (a dotted line is as wrong as
  // a smooth rope: real debris is lumpy and continuous).
  float b1=ang*9.5,b1i=floor(b1),b1f=fract(b1);
  float bead1=mix(.45,1.,pow(max(0.,1.-abs(2.*b1f-1.)),1.5))
              *(.62+.7*fract(sin(b1i*78.233+u_seed*.031)*3758.5453));
  float b2=ang*2.3,b2i=floor(b2),b2f=fract(b2);
  float bead2=mix(.30,1.,pow(max(0.,1.-abs(2.*b2f-1.)),1.2))
              *(.5+1.0*fract(sin(b2i*17.77+u_seed*.007)*8317.19));
  float bead=bead1*bead2;
  dens=max(dens,exp(-d*d/(w*w))*fadeTail*bead);
 }
 // Unbound debris: along the parabola behind the pericenter point, spreading.
 vec2 prev=vec2(0.);
 for(int i=0;i<=12;i++){
  float u=float(i)/12.;
  float ang=-u*lead;
  float r=min(2.*rp/(1.+cos(clamp(ang,-2.6,2.6)))*(1.+u*max(tau,0.)*.03),45.);
  vec2 P=r*vec2(cos(om+sg*ang),sin(om+sg*ang));
  if(i>0){
   vec2 ab=P-prev;float t=clamp(dot(X-prev,ab)/max(dot(ab,ab),1e-4),0.,1.);
   vec2 d=X-prev-ab*t;
   float w=(.30+.022*length(P)+.3*u)*.55;
   float t1=u*15.,t1i=floor(t1),t1f=fract(t1);
   float tb1=mix(.40,1.,pow(max(0.,1.-abs(2.*t1f-1.)),1.6))
             *(.55+.9*fract(sin(t1i*51.77+u_seed*.017)*9173.31));
   float t2=u*4.,t2i=floor(t2),t2f=fract(t2);
   float tb2=mix(.35,1.,pow(max(0.,1.-abs(2.*t2f-1.)),1.3))
             *(.5+1.0*fract(sin(t2i*23.31+u_seed*.011)*6137.53));
   dens=max(dens,exp(-dot(d,d)/(w*w))*.55*tb1*tb2);
  }
  prev=P;
 }
 return dens*grow*(.4+.8*exp(-max(tau,0.)/25.));
}
vec3 tdeStreamColor(float r){
 if(u_pal_a>8.5)return mixOk(srgbLin(vec3(.878,.188,.620)),srgbLin(vec3(.133,.827,.933)),clamp(1.3-r*.06,0.,1.))*1.8;
 if(u_pal_a<.5||u_pal_a>6.5)return palette(clamp(.95-r*.03,.3,.95))*1.6;
 if(u_pal_a>2.5&&u_pal_a<3.5)return vec3(1.);
 return blackbodyRGB(mix(4500.,14000.,clamp(1.6/max(r*.25,.4),0.,1.)))*1.4;
}
#endif

#if BH_SCENE==4
// Galaxy seen at any distance: exponential disk with logarithmic spiral arms,
// dust lanes and star-forming knots, a flattened Gaussian bulge integrated
// along the ray in closed form, and a bright nuclear cluster. From inside
// the disk the same slab reads as a band across the sky.
vec3 galTint(vec3 c){
 if(u_pal_a>2.5&&u_pal_a<3.5)return vec3(dot(c,vec3(.3,.59,.11)));
 if(u_pal_a>8.5)return mix(c,dot(c,vec3(.3,.59,.11))*1.3*mixOk(srgbLin(vec3(.878,.188,.620)),srgbLin(vec3(.133,.827,.933)),.35),.6);
 if(u_pal_a<.5||u_pal_a>6.5)return mix(c,c.g*1.3*palette(.7),.45);
 return c;
}
float g_foot=1.;
vec3 galDisk(vec2 X){
 vec2 uv=X/(12.*max(u_gal.z,1.))+.5;
 if(any(lessThan(uv,vec2(0)))||any(greaterThan(uv,vec2(1))))return vec3(0.);
 // Two nested, mip-filtered clipmaps; blend by both world footprint and
 // distance to the inner boundary. No frame-time noise or new ray steps.
 vec3 wide=texture(u_galaxy_tex,uv).rgb;
 vec2 nearUV=(uv-.5)*32.+.5;
 float edge=max(abs(nearUV.x-.5),abs(nearUV.y-.5));
 float blend=(1.-smoothstep(.32,.48,edge))*(1.-smoothstep(8.,80.,g_foot));
 // Outside the clipmap overlap, its exact zero weight needs no fetch.
 // Keep the wide-field halo at one texture lookup, including M87.
 if(blend<=0.)return galTint(wide*.5*clamp(1.-u_zoom.z,0.,1.));
 // Circular stellar orbits in an artistically compressed nuclear plane.
 // Inverse-rotate by Kepler angular speed; eight resolved stars live in the
 // baked alpha channel. No per-star loop or new ray samples at frame time.
 if(u_galaxy_nucleus>.5){
  vec2 nuclear=nearUV-.5;float radius=max(length(nuclear)*.375,.008);
  float orbitRadius=.012+.012*clamp(floor((radius-.012)/.012+.5),0.,7.);
  float phase=-u_time*.018*.008*inversesqrt(orbitRadius*orbitRadius*orbitRadius);
  float cs=cos(phase),sn=sin(phase);
  nearUV=.5+mat2(cs,sn,-sn,cs)*nuclear;
 }
 vec4 detail=texture(u_galaxy_near_tex,clamp(nearUV,0.,1.));
 vec3 light=mix(wide,detail.rgb,blend)*.5*clamp(1.-u_zoom.z,0.,1.);
 if(u_galaxy_nucleus>.5)light+=detail.a*blend*vec3(.48,.64,1.);
 return galTint(light);
}
float lineGauss(vec3 o,vec3 d,float sig,float flat_){
 vec3 os=o*vec3(1.,1.,flat_),ds=d*vec3(1.,1.,flat_);
 float dl=length(ds);ds/=dl;
 float tc=-dot(os,ds);vec3 cp=os+ds*tc;
 float b2=dot(cp,cp);
 return exp(-b2/(sig*sig))*(.5+.5*tanh(1.13*tc/sig))*sig*1.772/dl;
}
vec3 galaxy(vec3 o,vec3 d){
 float Rd=max(u_gal.z,1.),H=Rd*mix(.02,.09,u_gal2.w);
 if(u_galaxy_kind==4.){
  // An elliptical has a projected spheroidal light profile, not a luminous
  // square slab in the spiral's plane. Sample the baked Sersic/globular halo
  // in the observer's tangent plane, with its nucleus at the same origin.
  vec3 sight=normalize(o),east=cross(sight,vec3(0,0,1));
  if(dot(east,east)<1e-6)east=vec3(1,0,0);else east=normalize(east);
  vec3 north=cross(east,sight),closest=o-d*dot(o,d);
  vec2 projected=vec2(dot(closest,east),dot(closest,north)*1.15);
  float front=smoothstep(-Rd,Rd,-dot(o,d));
  return galDisk(projected)*front*u_zoom.w;
 }
 vec3 c=vec3(0.);
 // Near the hole (u_zoom.z -> 1) the bulge and nuclear cluster would be a uniform
 // fog around the camera; they fade and the stars take over.
 c+=galTint(vec3(1.,.80,.55))*lineGauss(o,d,u_gal2.z,2.2)*(1.2/u_gal2.z)*clamp(1.-u_zoom.z,0.,1.);
 // Nuclear light is resolved in the near clipmap instead of a second
 // analytic Gaussian (saves its exp/tanh/normalization per ray).
 if(abs(d.z)>1e-5){
  float t=-o.z/d.z;
  float path=min(1./abs(d.z),6.);
  g_foot=(t+length(o-g_cam))*g_fw*path;
  if(t>0.)c+=galDisk((o+d*t).xy)*path*.5;
  if(abs(o.z)<H){                                   // inside the slab: the other side too
   float te=(sign(d.z)*H-o.z)/d.z;
   g_foot=(te*.5+length(o-g_cam))*g_fw*min(1./abs(d.z),12.);
   if(t<=0.)c+=galDisk((o+d*te*.5).xy)*min(te/H,20.)*.06;
  }
 }
 return c*u_zoom.w*.9;
}
#endif

#if BH_SCENE==0 || BH_SCENE==4
void traceSingle(vec3 cam,vec3 ray,vec3 diskN,vec3 right,float closeFX,
                 out vec3 color,out float trans,out bool captured,
                 out float impact,out vec3 dsky,out vec3 osky){
 color=vec3(0.);trans=1.;g_cam=cam;
 // A static observer tetrad: Euclidean ray components are LOCAL directions.
 float R=length(cam),observerMetric=max(1.-1./R,1e-6);
 vec3 normal=cam/R,perp=ray-normal*dot(ray,normal);
 float tang=length(perp);vec3 tangent=tang>1e-7?perp/tang:right;
 bool inward=dot(ray,normal)<0.;
 impact=R*tang/sqrt(observerMetric);
 float row=trRow(impact);vec2 end=trEnds(row);
 bool scatter=end.x<.9999; // integrated turning endpoint versus horizon u=1
 float start=trSample(u_tr_forward,1.-sqrt(max(1.-1./(R*end.x),0.)),row);
 float phase0=scatter&&!inward?2.*end.y-start:start;
 float direction=(!scatter&&!inward)?-1.:1.;
 float finish=scatter?2.*end.y:inward?end.y:0.;
 float extent=abs(finish-phase0);
 // Critical strip cannot be assigned an escape direction. Black unresolved
 // coverage is a bounded angular approximation, never a fabricated sky ray.
 bool unresolved=inward&&abs(impact/2.598076211353316-1.)<exp(-16.);
 captured=(!scatter&&inward)||unresolved;
 g_observer=observerMetric;
 float visibleExtent=extent;
 float crossing=atan(-dot(diskN,normal),dot(diskN,tangent));
 crossing=mod(crossing,PI);
 if(crossing<1e-6)crossing+=PI;
 // Exactly coplanar rays use the empty-sheet limit; no arbitrary cutout.
 bool coplanar=abs(dot(diskN,normal))+abs(dot(diskN,tangent))<1e-7;
 for(int k=0;k<12;k++){
  float phi=crossing+float(k)*PI;
  if(phi>=extent||coplanar||unresolved)break;
  float phase=phase0+direction*phi;
  float folded=scatter?min(phase,2.*end.y-phase):phase;
  float u=trSample(u_tr_inverse,folded/end.y,row);
  float r=1./max(u,1e-10);
  // Count geometric crossings, including the central gap. The surface is
  // opaque: only the nearest intersection in the emitting annulus is seen.
  if(r>=3.&&r<=u_disk_out&&u_disk_emission>0.){
   vec3 radial=normal*cos(phi)+tangent*sin(phi);
   vec3 angular=-normal*sin(phi)+tangent*cos(phi);
   float nt=clamp(impact*u*sqrt(max(1.-u,0.)),0.,1.);
   bool incoming=scatter?phase<end.y:inward;
   vec3 backwards=(incoming?-1.:1.)*sqrt(max(1.-nt*nt,0.))*radial+nt*angular;
   g_photon=-backwards;
   g_hit=float(k);
   float orderGain=k<2?1.:1.+u_photon_ring+.25*u_images;
   color=orderGain*disk_color(radial*r,diskN,closeFX);
   visibleExtent=phi;trans=0.;break;
  }
 }
 // Integrate only the visible bent path, stopping at the first opaque disk
 // crossing or horizon. No straight-ray overlay and no work when jet=0.
 if(u_jet>0.&&u_jet_duty>0.&&!unresolved){
  vec3 axis=u_jet_axis<.5?normalize(u_spin_axis.xyz):diskN;
  if(u_enh>.5){
   vec3 e=normalize(cross(axis,abs(axis.z)<.9?vec3(0,0,1):vec3(0,1,0)));
   axis=normalize(axis+.06*(e*cos(u_time*.07)+cross(axis,e)*sin(u_time*.07)));
  }
  // Trim the infinite escaping tail to the finite emitting volume.
  float edgePhase=trSample(u_tr_forward,1.-sqrt(max(1.-1./(max(4.*u_jet_len,4.)*end.x),0.)),row);
  float begin=max(0.,inward?edgePhase-phase0:0.);
  float stop=min(visibleExtent,scatter?2.*end.y-edgePhase-phase0:inward?extent:phase0-edgePhase);
#if BH_LIGHT
  const int JET_SAMPLES=16;
#else
  const int JET_SAMPLES=32;
#endif
  float stepPhi=max(stop-begin,0.)/float(JET_SAMPLES);
  for(int j=0;j<JET_SAMPLES;j++){
   float phi=begin+(float(j)+.5)*stepPhi,phase=phase0+direction*phi;
   float folded=scatter?min(phase,2.*end.y-phase):phase;
   float u=trSample(u_tr_inverse,folded/end.y,row),r=1./max(u,1e-8);
   vec3 radial=normal*cos(phi)+tangent*sin(phi);
   vec3 angular=-normal*sin(phi)+tangent*cos(phi);
   float nt=clamp(impact*u*sqrt(max(1.-u,0.)),0.,1.);
   bool incoming=scatter?phase<end.y:inward;
   vec3 photon=-((incoming?-1.:1.)*sqrt(max(1.-nt*nt,0.))*radial+nt*angular);
   float properLength=r*stepPhi/max(nt,1e-6);
   color+=u_jet*u_jet_duty*properLength*jet_emission(radial*r,axis,photon);
  }
 }
 float skyPhi=extent;
 dsky=normalize(normal*cos(skyPhi)+tangent*sin(skyPhi));
 osky=-impact*(-normal*sin(skyPhi)+tangent*cos(skyPhi));
}
#endif
void main(){
 vec2 p=(2.*(gl_FragCoord.xy+u_jitter)-u_resolution)/u_resolution.y/u_radius+u_drift;
 g_dout=u_disk_out;
 g_fw=1.5/(u_resolution.y*u_radius);   // radians per pixel (vertical field ~ 2/u_radius)
 // Per-launch flight-path parameters replace what used to be hardcoded
 // curve coefficients. The four modes are gone; replaced by two REAL
 // trajectory families from orbital mechanics (zoom-whirl for bound,
 // hyperbolic flyby for unbound). One equation per family gives
 // unlimited distinct paths from a single per-launch `q` (zoom-whirl)
 // or eccentricity (both) draw.
 //
 // u_camera_family (scalar): 0 = zoom-whirl, 1 = hyperbolic flyby.
 // u_orbit_q (scalar): zoom-whirl ratio of angular to radial frequency.
 //   q rational -> closed periodic rosette. q irrational -> aperiodic,
 //   never repeats. Default 1 (unused for the flyby family).
 // u_orbit_e (scalar): eccentricity. Zoom-whirl draws [0.15, 0.7];
 //   flyby draws > 1 in [1.05, 3.0].
 // Use a SINGLE pass for the unbound flyby (don't multiply phase by
 // u_path_o_count; that would loop the flyby into back-to-back
 // identical passes). For bound zoom-whirl, u_path_o_count controls
 // how many radial cycles the camera traces before wraparound.
 float phase;
 float orbit,elev,dist,roll=0.,closeFX=0.,arrivalFX=0.;
 if(u_camera_family<.5){
  // ZOOM-WHIRL: phase is radians of true anomaly, advancing at
  // orbit_rate*o_count so o_count controls how many radial cycles
  // fit in the screensaver. Three orbits at q=3 = nine-leaf rosette.
  phase=u_time*u_orbit_rate*u_path_o_count+u_seed*.000001+u_path_phase_jitter;
  // ---- ZOOM-WHIRL (bound) ----
  //
  // Real relativistic phenomenon with no Newtonian analogue. The
  // camera zooms out to apoapsis and back, then whirls through
  // several revolutions at periapsis. q = ratio of angular to radial
  // frequency per radial cycle. ONE equation gives unlimited distinct
  // paths; q rational -> closed rosette, q irrational -> aperiodic,
  // never repeats.
  //
  // Parameterise by phase angle u (radians, monotonic with time).
  //   Radial:        r(u)   = p / (1 + e cos(u - omega))
  //   Orbital angle: psi(u) = q * (u - omega) + omega
  // so the camera makes q revolutions per radial cycle, with the
  // fastest sweep at periapsis.
  //
  // p derived from the periapse radius r_p: r_p = p/(1 + e), so
  // p = r_p (1 + e). u_periapsis is the closest approach in M.
  float u_=phase;
  float p_=u_periapsis*(1.+u_orbit_e);
  float cu=cos(u_-u_orbit_omega);
  float r_=p_/(1.+u_orbit_e*cu);
  r_=max(r_,5.5);   // stay outside event horizon
  float psi=u_orbit_q*(u_-u_orbit_omega)+u_orbit_omega;
  orbit=u_path_sign*psi;
  dist=r_;
  // Elevation oscillation: same parameterisation as before so
  // per-launch e_swing / e_freq still produce visible variety.
  elev=u_inclination+u_path_e_swing*sin(u_*u_path_e_freq);
  // closeFX / arrivalFX used by the integrator for peripheral
  // distortion; for bound orbits they ride the periapse passages.
  // closeFX peaks when r is near periapsis.
  float closeness=1.-clamp((r_-u_periapsis)/(u_periapsis*4.),0.,1.);
  closeFX=closeness*closeness;
  arrivalFX=4.*closeFX*(1.-closeFX);
 }else{
  // HYPERBOLIC FLYBY: ONE pass from one asymptote to the other.
  // u_path_o_count scales how often the sweep repeats (each cycle
  // is one asymptote-to-asymptote pass). phase = sine of time so
  // the camera oscillates between asymptotes smoothly without
  // edge discontinuities; combined with the radial discontinuity
  // avoidance by clamping `fu` to the asymptote range, this gives
  // a "bouncing through" flyby that doesn't tear at the wrap.
  float t=u_time*u_orbit_rate*u_path_o_count;
  // MONOTONIC ONE-WAY SWEEP (2026-10-29). This used to be phase=sin(t), so the
  // camera flew in and then retraced the same path backwards, forever, on a
  // fixed period -- the "very static view" an operator reported. A flyby is a
  // single pass: parameterise by a sawtooth in time.
  float _fInf=acos(clamp(-1./max(u_orbit_e,1.0001),-1.,1.));   // asymptote anomaly
  float _sweep=2.*_fInf*.92;                                   // stay inside the asymptotes
  float _tt=fract(t/max(_sweep,1e-4));
  phase=-_fInf*.92+_sweep*_tt;
  // ---- HYPERBOLIC FLYBY (unbound) ----
  //
  // Voyager-gravity-assist geometry. Incoming asymptote, periapse, outgoing
  // asymptote; the camera arrives, slings past and departs.
  //
  // BUG FIXED 2026-10-29 (found by reviewing with MiniMax-M3): the conic used
  // cos(fu-u_orbit_omega) while fu only spanned +/-half_sweep. With e>1 and a
  // large omega the denominator 1+e*cos(fu-omega) goes NEGATIVE, r_ goes
  // negative, and r_=max(r_,5.5) then pins the camera at a constant distance --
  // a frozen view. The conic is a function of the true anomaly ALONE; omega
  // rotates the whole trajectory in the plane and is applied to the resulting
  // angle, never inside r().
  float fu=clamp(phase,-_fInf*.92,_fInf*.92);
  float p_=u_periapsis*(1.+u_orbit_e);
  float r_=p_/(1.+u_orbit_e*cos(fu));                          // always > 0 for |fu| < f_inf
  r_=clamp(r_,u_periapsis*1.02,1e4);                           // guard only, never a park
  orbit=u_path_sign*(fu+u_orbit_omega+u_approach*.1);
  dist=r_;
  elev=u_inclination+u_path_e_swing*sin(phase*u_path_e_freq);
  closeFX=1.-clamp(r_/(u_periapsis*8.),0.,1.);
  arrivalFX=4.*closeFX*(1.-closeFX);
 }
 bool useFly=u_flyby>.5;
 vec3 camV=vec3(0.),upH=vec3(0.,0.,1.);
 if(useFly){
  // Deterministic flyby camera: a curve in an orbital plane through the hole.
  // Plane inclination ii, node angle Om (from the per-cycle variation), radial
  // profile and angle by type. All functions of u_fly_t, so paths are smooth.
  float ty=u_flyby,f=u_fly_t,ff=fract(f),Om=u_fly_var*6.2831853;
  float sg=(fract(u_fly_var*7.31)<.5)?1.:-1.;
  float rr=.5*(u_dmin+u_dmax),nu=0.;
  float ii=(u_incl>=0.)?u_incl:.32+.3*(fract(u_fly_var*3.7)-.5);
  if(ty<2.5){
   nu=sg*6.2831853*f;                       // circular orbit, one revolution per cycle
  }else if(ty<4.5||(ty>5.5&&ty<7.5)){
   // Hyperbolic pass: equatorial (3), polar (4), slingshot (6).
   float e=(ty>5.5)?1.18:1.6;
   float nmax=acos(-1./e)*((ty>5.5)?.96:.93);
   nu=sg*nmax*sin((2.*ff-1.)*1.5707963);    // slow at the ends, fast at periapsis
   float r0=u_dmin*(1.+e)/(1.+e*cos(nu));
   rr=1./(1./r0+1./u_dmax)*(1.+u_dmin/u_dmax);   // soft cap: exactly dmin at periapsis
   if(u_incl<0.)ii=(ty<3.5)?.04:((ty<4.5)?1.5:.35);
  }else if(ty<5.5){
   // Plunge: dive to dmin and climb back out while sweeping through 1.4 pi.
   float c=cos(3.14159265*ff);
   rr=u_dmin+(u_dmax-u_dmin)*c*c;
   nu=Om+sg*4.4*ff;
   if(u_incl<0.)ii=.4;
  }else if(ty==8.){
   // Sweep: continuous inclination sweep. The camera holds its azimuth and
   // distance and moves only in inclination, so the system keeps its own
   // spin-axis orientation in the frame. With disk-inclination auto the disk
   // follows the camera exactly as the other paths do; with an explicit
   // disk-inclination the camera sweeps around the fixed disk (the same
   // system seen from many viewing angles).
   // The base is the per-cycle draw of the other flyby paths, raised so the
   // swing reaches near-face-on instead of near-vertical. Cosine easing:
   // position is C1 at both ends (zero velocity at the reversal, no jump) and
   // C-infinite at the cycle boundary; sweep-phase shifts the starting
   // angle and sweep-range its half-amplitude. Only the direction comes from
   // the seed (sg), so a given seed and t give the same angles every launch.
   ii=max(ii,.7);
   nu=Om;                                     // fixed azimuth
   rr=.5*(u_dmin+u_dmax);                     // fixed distance
   ii+=sg*u_sweep_range*.017453292*cos(6.2831853*f+u_sweep_phase*.017453292);
  }else{
   // Drift: slow closed Lissajous-like wandering (periodic in ff).
   rr=mix(u_dmin,u_dmax,.5+.5*sin(6.2831853*ff+Om));
   nu=sg*6.2831853*ff;
   ii+=.3*sin(12.5663706*ff+Om*1.7);
  }
  rr=max(rr,u_dmin);
  vec3 e1=vec3(cos(Om),sin(Om),0.),e2=vec3(-sin(Om)*cos(ii),cos(Om)*cos(ii),sin(ii));
  camV=rr*(cos(nu)*e1+sin(nu)*e2);
  vec3 nn=normalize(cross(e1,e2));if(nn.z<0.)nn=-nn;
  upH=nn;                                    // plane normal is "up": stable horizon
  dist=rr;
  float cl=1.-clamp((rr-u_dmin)/(u_dmin*3.),0.,1.);
  closeFX=cl*cl;arrivalFX=4.*cl*(1.-cl);
 }
 if(u_camo.w>.5){
  camV=u_camo.xyz;dist=length(camV);useFly=true;upH=vec3(0.,0.,1.);
  float cl=1.-clamp((dist-3.2)/30.,0.,1.);
  closeFX=cl*cl;arrivalFX=4.*cl*(1.-cl);
 }
 dist=max(dist,useFly?3.2:5.4);
#if BH_SCENE==4
 // The galaxy zoom owns the camera: high above the disk while the whole galaxy
 // is in view, sinking toward the plane as it dives to the nucleus.
 if(u_zoom.x>0.){
  dist=max(u_zoom.x,3.4);
  float closingElevation=u_galaxy_kind==4.?1.274:u_galaxy_kind==2.?1.047:.36;
  float el=mix(u_galaxy_kind==7.?.18:mix(.18,1.22,u_gal2.x),closingElevation,u_zoom.z),az=u_gal.w*.5;
  camV=vec3(cos(el)*cos(az),cos(el)*sin(az),sin(el));useFly=true;upH=vec3(0.,0.,1.);
 }
#endif
 vec3 cam=useFly?camV*(dist/max(length(camV),1e-4)):dist*vec3(cos(orbit)*cos(elev),sin(orbit)*cos(elev),sin(elev)),forward=normalize(-cam),baseRight=normalize(cross(forward,upH)),baseUp=cross(baseRight,forward),right=cos(roll)*baseRight+sin(roll)*baseUp,up=-sin(roll)*baseRight+cos(roll)*baseUp;
 // --- PROBE MOTION (operator, 2026-10-29) ---------------------------------
 // "there needs to be more movement, as if the black hole is being observed by
 // a moving space probe (aka Voyager 2 classic flyby of Saturn/Jupiter)".
 // The director and the legacy paths can both park the eye, and a parked eye
 // with a face-on disk reads as a still no matter how fast the disk spins --
 // the aim pan alone cannot fix that, because a perfectly aligned disk is
 // rotationally symmetric. So the EYE itself always translates: a slow,
 // bounded epicycle with three incommensurate periods (83 / 127 / 211 s) so it
 // never visibly repeats, ~3.5% of the distance laterally and ~2% radially
 // plus a vertical component that opens and closes the disk's apparent ellipse
 // ("disc alignment"). The aim clamp below re-centres the hole and the size
 // clamp keeps its apparent radius, so this adds parallax, not drift off frame.
 if(u_flight_view.w<.5){
  vec3 _pmFwd=normalize(cam);
  vec3 _pmA=cross(_pmFwd,vec3(0.,0.,1.));
  if(length(_pmA)<1e-4)_pmA=vec3(1.,0.,0.); else _pmA=normalize(_pmA);
  vec3 _pmB=normalize(cross(_pmFwd,_pmA));
  float _lat = sin(u_time*.0757)*.022 + sin(u_time*.0496+1.7)*.014;
  float _vert= sin(u_time*.0431+.9)*.020 + sin(u_time*.0729+2.3)*.008;
  float _rad = sin(u_time*.0298+2.9)*.020;
  cam = cam*(1.+_rad) + _pmA*(_lat*dist) + _pmB*(_vert*dist);
 }
 // Disk normal at this frame. Used for the plane-crossing detection in
 // the integrator (line 318) and the jet axis check (line 320). Computing
 // it once per frame avoids recomputing the Rodrigues rotation in inner
 // loops. Falls back to +Z if the draw produced a near-degenerate axis
 // (probability zero from a uniform-on-sphere draw, but it's cheap).
 vec3 diskN=diskNormalAtTime(u_time);
 vec3 jetAxis=u_jet_axis<.5?normalize(u_spin_axis.xyz):diskN;
 // Only a degenerate draw falls back to +Z. The flyby paths already resolve
 // to +Z on the host side (disk_axis = 0,0,1), which is the old behaviour;
 // an explicit --disk-tilt or spin-axis override is kept for every path,
 // because the user asked for it.
 if(length(diskN)<.5)diskN=vec3(0.,0.,1.);
 // One ray, with subtle arrival-only peripheral distortion and framing drift.
 float r2=dot(p,p),shot=fract(u_time*u_orbit_rate/(2.*PI));
 vec2 lensP=p*(1.+.035*arrivalFX*r2/(1.+r2));
 lensP+=closeFX*vec2(u_path_sign*.12*sin(2.*PI*shot),.06);
 // Handoff viewing geometry (docs/BLACKHOLE-OPTIONS.md): the two observer
 // angles supply the preferred ray basis. The path supplies the eye position;
 // the safety aim below can rotate or pan the ray to retain the subject.
 //   u_view_geom.x = observer inclination to the disk plane
 //   u_view_geom.y = sky position angle
 // Only the view ray is built in the observer basis and converted to world;
 // every scene vector remains in world space.
 // --- subject size invariant (operator rule, 2026-10-28) -------------------
 // "The camera director can zoom in and zoom out for variance, but it must
 // always be in view." Aim alone (below) keeps the SHADOW inside the box but
 // says nothing about its SIZE: at a far enough eye the hole is a dot, and at
 // a close enough one it fills the frame and the disk works off screen. So the
 // eye distance is clamped before the basis is built, using the same apparent
 // radius model the tracking tests assert:
 //     r = 1.3 * M * u_radius / d      (fraction of frame height)
 // and the operator's band, now 5% .. 25% (a 40% radius let the shadow fill 80% of
 // the frame, which reads as an empty dark view -- operator screenshot 2026-10-28). Variance inside the band is untouched,
 // which leaves a 13x zoom range for the director to play with.
 vec3 focus=vec3(0.);
 float focusMass=0.;
#if BH_MULTI
 float totalMass=0.;
 for(int k=0;k<3;k++){
  float mass=max(u_holes[k].w,0.);
  focus+=mass*u_holes[k].xyz;
  totalMass+=mass;
 }
 if(totalMass>0.)focus/=totalMass;
 focusMass=max(u_holes[0].w,0.);
#else
 focusMass=max(u_holes[0].w,0.);
#endif
 if(focusMass>0. && u_flight_view.w<.5){
  float _d=length(cam-focus);
  if(_d>1e-4){
   float _lens=max(u_radius,1e-4);
   float _k=1.3*focusMass*_lens;
   float _lo=0.05,_hi=0.25;
   float _dMin=_k/_hi;      /* closest eye that keeps the shadow <= 25% */
   float _dMax=_k/_lo;      /* farthest eye that keeps the shadow  >= 5%  */
   float _safeMin=max(_dMin,3.2*focusMass);
   float _dC=clamp(_d,_safeMin,max(_safeMin,_dMax));
   if(abs(_dC-_d)>1e-4)cam=focus+normalize(cam-focus)*_dC;
  }
 }
 if(u_framing>.5 && !useFly){
  float az=u_time*.012+u_seed*.001;
  float R=u_close_distance>0.?u_close_distance:8.5*max(u_radius,.5);
  float el=u_incl>=0.?u_incl:.174532925;
  cam=R*vec3(cos(az)*cos(el),sin(az)*cos(el),sin(el));
  if(u_framing<1.5)diskN=vec3(0.,0.,1.);
 }
 ViewXform vx=viewXform(cam);
 // Keep the path's actual eye. Replacing it with vx.cam discarded all
 // tangential motion when the viewing angles were pinned, leaving circular
 // paths at a constant radius completely static.
 // The basis still follows the explicit viewing angles; the eye stays at cam.
 // Project the lensing subject through the exact basis used for this ray.
 // The single-hole focus is the origin. For scenes, follow the mass-weighted
 // centroid while bounding every projected shadow that fits in the safe box.
 vec3 toFocus=focus-cam;
 float focusDepth=dot(toFocus,-vx.los);
 // Keep the requested viewing angles whenever a finite screen pan can track
 // the hole. Only re-aim the basis when the path carries the eye behind that
 // preferred view or more than half a lens unit away from it.
 vec2 preferredP=vec2(dot(toFocus,vx.right),dot(toFocus,vx.up))
                 /max(focusDepth,1e-4);
 if(focusDepth<=1e-4 || max(abs(preferredP.x),abs(preferredP.y))>0.5){
  vec3 subjectLos=normalize(cam-focus);
  vec3 subjectRight=cross(subjectLos,vx.up);
  if(length(subjectRight)<1e-5)subjectRight=vx.right;
  vx.right=normalize(subjectRight);
  vx.up=normalize(cross(vx.right,subjectLos));
  vx.los=subjectLos;
  focusDepth=dot(toFocus,-vx.los);
 }
 focusDepth=max(focusDepth,1e-4);
 vec2 focusP=vec2(dot(toFocus,vx.right),dot(toFocus,vx.up))/focusDepth;
 // The shader's p coordinate spans 2/u_radius across the smaller dimension.
 // A 12% screen margin is 0.24/u_radius in lens coordinates. Reserve one
 // percentage point for the small nonlinear arrival distortion above.
 // The aim box used to be 12% of the frame, which let a dramatic pass park the
 // hole a quarter of the way in from the edge (measured on the Voyager flight
 // plans, 2026-10-29: Neptune 0.66, New Horizons 0.55). The operator's rule is
 // that the camera always turns toward the hole the way a probe turns toward
 // its target, so the box is tightened to ~4%: composition may breathe, the
 // subject may not leave the middle.
 float safe=0.075/max(u_radius,1e-4);
 // MOTION FLOOR (operator rule, 2026-10-28: "we should never produce
 // visualizations with static looking views, they should always be moving").
 // A scene whose path and director both park the composition, with the disk
 // edge-on or its emission gated low, renders a still that reads as a broken
 // saver. When the drift the C side supplies is negligible, add a slow
 // two-frequency orbital drift so the subject keeps breathing at every preset
 // and every seed. It is small enough to leave a genuinely moving shot alone.
 vec2 motionFloor=0.020*vec2(cos(u_time*0.11),sin(u_time*0.083));
 vec2 driftV=u_drift+(length(u_drift)<0.012?motionFloor:vec2(0.));
 float driftR2=dot(driftV,driftV);
 vec2 rawCenter=driftV*(1.+.035*arrivalFX*driftR2/(1.+driftR2))
                +closeFX*vec2(u_path_sign*.12*sin(2.*PI*shot),.06);
 vec2 aim=focusP-clamp(focusP-rawCenter,vec2(-safe),vec2(safe));
#if BH_MULTI
 vec2 aimLo=vec2(-1e6),aimHi=vec2(1e6),primaryP=focusP;
 for(int k=0;k<3;k++){
  if(u_holes[k].w<=0.)continue;
  vec3 toHole=u_holes[k].xyz-cam;
  float holeDepth=max(dot(toHole,-vx.los),1e-4);
  vec2 holeP=vec2(dot(toHole,vx.right),dot(toHole,vx.up))/holeDepth;
  if(k==0)primaryP=holeP;
  aimLo=max(aimLo,holeP-vec2(safe));
  aimHi=min(aimHi,holeP+vec2(safe));
 }
 // The mass-weighted centroid remains the preferred aim. If all shadows
 // fit, the interval intersection keeps each one inside the same box.
 // When their separation makes that impossible, retain the primary.
 if(all(lessThanEqual(aimLo,aimHi)))aim=clamp(aim,aimLo,aimHi);
 else aim=clamp(aim,primaryP-vec2(safe),primaryP+vec2(safe));
#endif
 lensP+=aim-rawCenter;
 if(u_observer_probe>.5){fragColor=vec4(length(cam),u_radius,0.,1.);return;}
 if(u_flight_view.w>.5){
  float az=u_flight_view.x,el=u_flight_view.y,bank=u_flight_view.z;
  vx.los=vec3(cos(el)*cos(az),cos(el)*sin(az),sin(el));
  vec3 rr=normalize(cross(vx.los,vec3(0,0,1))),uu=cross(rr,vx.los);
  vx.right=cos(bank)*rr+sin(bank)*uu;vx.up=-sin(bank)*rr+cos(bank)*uu;
  lensP=p-u_drift;right=vx.right;up=vx.up;
 }
 vec3 ray=normalize(toWorld(vx,vec3(lensP.x,lensP.y,1.)));
 float observerD=1.;
 if(u_flight_view.w>.5)ray=flightAberration(ray,u_flight_beta,observerD);
 vec3 skyShift=pow(observerD,4.)*vec3(pow(observerD,-.25),1.,pow(observerD,.25));
 // One hash per property, incommensurate moduli so the four do not move together.
 {
  float h1=fract(sin(mod(u_seed,3571.)*12.9898)*43758.5453);
  float h2=fract(sin(mod(u_seed,6091.)*78.233)*24634.6345);
  float h3=fract(sin(mod(u_seed,7919.)*37.719)*13921.0473);
  float h4=fract(sin(mod(u_seed,4561.)*93.917)*31337.1300);
  g_diskTurb=.55+1.15*h1;      // turbulent contrast 0.55 .. 1.70
  g_diskFreq=.62+.85*h2;       // filament radial scale (fine .. coarse)


 }
 vec3 color=vec3(0);float trans=1.;bool captured;float impact;vec3 dsky,osky;
 float tdisk=1e9;   // distance along the ray to the FIRST disk crossing (1e9 = none)
 g_cam=cam;
#if BH_MULTI
 // Gravitational-wave ripples: the straight view ray meets the orbital plane;
 // the quadrupole field there nudges the ray (a lensing shimmer of everything
 // behind) and lights faint spiral bands.
 float gwGlow=0.;
 if(u_gw.x>0.&&abs(ray.z)>1e-4){
  float t0=-cam.z/ray.z;
  if(t0>0.){
   vec3 X=cam+ray*t0;float R=length(X.xy);
   float h=gwField(X.xy);
   ray=normalize(ray+u_lensing*(.010*h*vec3(X.xy/max(R,1e-3),0.)+.006*h*up));
   gwGlow=h;
  }
 }
 // Ringdown: the remnant's shadow rings as a decaying, rotating quadrupole.
 if(u_fx.y>0.&&u_holes[0].w>0.){
  vec3 c=u_holes[0].xyz;float rs=u_holes[0].w;
  float tca=dot(c-cam,ray);vec3 bv=cam+ray*tca-c;float b=length(bv);
  float ang=atan(dot(bv,up),dot(bv,right));    // enters only via cos(2 ang): no seam
  float w=u_fx.y*cos(2.*ang-u_gw2.w*u_gw2.x)*exp(-max(b-2.6*rs,0.)/(2.5*rs));
  ray=normalize(ray-u_lensing*w*(1.2*rs/length(cam))*bv/max(b,1e-3));
 }
 traceMulti(cam,ray,closeFX,color,trans,captured,dsky,osky);
 impact=1e9;
 for(int k=0;k<3;k++){
  if(u_holes[k].w<=0.)continue;
  impact=min(impact,length(cross(u_holes[k].xyz-cam,ray))/u_holes[k].w);
 }
#else
#if BH_SCENE==0 || BH_SCENE==4
#if BH_SCENE==4
 // At galactic distances, rays missing the entire emitting volume can use
 // the finite-observer weak-field expansion. With b>=256 rs, the omitted
 // second-order term is <4.5e-5 rad (<0.04 px at the default 1508x848 lens).
 // All disk/jet crossings and strong lensing retain the trajectory atlas.
 float distantImpact=length(cross(cam,ray));
 if(length(cam)>600.&&distantImpact>max(256.,max(u_disk_out+1.,4.*u_jet_len))){
  impact=distantImpact;captured=false;color=vec3(0.);trans=1.;osky=cam;
  vec3 offset=cam-ray*dot(cam,ray);
  dsky=normalize(ray-offset*(1.+clamp(-dot(cam,ray)/length(cam),-1.,1.))/(impact*impact));
 }else
#endif
 traceSingle(cam,ray,diskN,right,closeFX,color,trans,captured,impact,dsky,osky);
#else
 impact=length(cross(cam,ray));captured=true; // until escape is observed
 // The companion and its stream live in the disk plane and are evaluated at
 // the integrator's world-space positions (old, pos), so they are built from
 // the world disk normal, like the rest of the scene.
 if(u_comp>0.)compInit(cam,diskN);
 float u=1./length(cam),phi=0.;vec3 normal=normalize(cam),perp=cross(cross(normal,ray),normal);float plen=length(perp);vec3 tangent=plen>1e-6?perp/plen:right;float tang=dot(ray,tangent),du=abs(tang)>1e-6?-dot(ray,normal)/tang*u:200.*u;vec3 old=cam,pos=cam;int nhit=0;
 // Disk-plane crossing test against diskN (the plane through the origin
 // with normal diskN). When old and pos are on opposite sides, their dot
 // products with diskN differ in sign and the segment crosses the disk.
 // The intersection point x lands in the disk plane up to fp precision;
 // we project it onto diskN=0 just to be sure, then take its radial dist
 // to gate the 2.8..13 band. The radial dist is taken in world XY because
 // the disk normal can be non-+Z; in disk_color the point is rotated into
 // the disk-local frame and the actual polar coords (r,a) live there.
 for(int i=0;i<int(u_max_steps);i++){
   float step=.04*(1.-.62*exp(-12.*(u-.667)*(u-.667)));
   du+=.5*(-u+u_lensing*1.5*u*u)*step;
   u+=du*step;
   du+=.5*(-u+u_lensing*1.5*u*u)*step;
   phi+=step;
   if(u>=1.){captured=true;break;}
   if(u<=.0005){captured=false;break;}
   old=pos;
   pos=(cos(phi)*normal+sin(phi)*tangent)/u;
   if(u_flow>.5){
#if BH_SCENE==3
    g_dout=u_tde3.z;g_soft=3.;
    float flowBrightness=u_tde3.w;
#else
    float flowBrightness=1.;
#endif
    float dl=length(pos-old)*.25;
    for(int j=0;j<4;j++){
     vec3 mid=toDiskLocal(mix(old,pos,(float(j)+.5)*.25),diskN);
     vec3 emitted=flowBrightness*flow_sample(mid,1.,dl,closeFX);
     color+=trans*emitted;
     trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
    }
   }
   if(u_comp>0.&&compSeg(old,pos,color,trans))break;
  if(u_corona>0.){
   // Corona in the same bounded step as the flow: world midpoint, the hole
   // at the origin (single scene), r_s = 1. It is accumulated into `color`
   // before the disk crossing of this segment is tested, so the disk's
   // transmission still attenuates it; the capture shadow blocks it because
   // the ray never passes through the hole. It is NOT gated by
   // u_disk_emission (a separate component) but shares the tonemap/exposure
   // path, being part of `color`.
   vec3 mid=.5*(old+pos);
   vec3 emitted=corona_sample(mid,(length(pos-old)));
   color+=trans*emitted;
   trans*=1.-clamp(dot(emitted,vec3(.2126,.7152,.0722))*.08,0.,.12);
  }
#if BH_SCENE==3
   {vec4 st=tdeStar(old,pos);if(st.w>0.){color+=trans*st.rgb;trans=0.;captured=true;break;}}
#endif
   float od=dot(old,diskN);
   float pd=dot(pos,diskN);
   if(od*pd<0.&&od!=pd){
    float t_=-od/(pd-od);
    vec3 x=mix(old,pos,t_);
    x=x-diskN*dot(x,diskN);
    float rd=length(x);
#if BH_SCENE==3
    // disk plane = orbital plane of the star (scenes always use a flyby path, diskN = +Z)
    if(rd>u_isco-.2&&rd<70.){
     g_hit=float(nhit);nhit++;
     g_dout=u_tde3.z;g_soft=3.;
     vec3 e=(u_flow<.5&&rd<u_tde3.z+1.&&u_tde3.w>0.)?disk_color(x,diskN,closeFX)*u_tde3.w:vec3(0.);
     float sd=tdeStream(x.xy);
     e+=u_disk_emission*sd*tdeStreamColor(rd)*(1.+1.4*u_tde3.y);
     // disk-emission also gates the TDE stream and its opacity, so dark-lens
     // is dark in this scene too (review 2026-10-27: both bypassed it).
     color+=trans*e;
     if(sd>.05||(u_flow<.5&&rd<u_tde3.z+1.))trans*=1.-.28*u_disk_emission;
    }
#else
    if(u_flow<.5&&rd>u_isco-.2&&rd<u_disk_out+1.){
     g_hit=float(nhit);nhit++;
     // x is already a world-space point (pos is built from world normal and
     // tangent), and disk_color shades in world space via toDiskLocal, so it
     // is passed through unchanged.
     tdisk=min(tdisk,length(x-cam));
     color+=trans*disk_color(x,diskN,closeFX);
     trans*=1.-.28*u_disk_emission;

    }
#endif
   }
  }
 dsky=length(pos-old)>1e-5?normalize(pos-old):ray;
 // Escaped rays leave the integrator at slightly different radii (whole
 // steps); use the point of the outgoing asymptote closest to the hole as the
 // ray origin so scene backgrounds sampled along it (galaxy) are continuous.
 osky=pos-dsky*dot(pos,dsky);
 if(dot(cam-pos,cam-pos)<1e-6)osky=cam;
#endif
#endif
 // Angular size of one pixel in the (lensed) sky, for star sizes. Taken here,
 // outside all branches, where derivatives are defined.
 float fw=length(fwidth(dsky));
 float criticalWidth=fwidth(impact);
 vec3 rayDx=dFdx(ray),rayDy=dFdy(ray);
 {
  float nA,pbA,hzA;vec3 bsA,stA,ntA,hlA;
  palSky(u_pal_a,nA,bsA,stA,ntA,hlA,pbA,hzA);
  float nM=nA,pbM=pbA,hzM=hzA;vec3 bsM=bsA,stM=stA,ntM=ntA,hlM=hlA;
  if(u_pal_mix>.001){
   float nB,pbB,hzB;vec3 bsB,stB,ntB,hlB;
   palSky(u_pal_b,nB,bsB,stB,ntB,hlB,pbB,hzB);
   nM=mix(nA,nB,u_pal_mix);pbM=mix(pbA,pbB,u_pal_mix);hzM=mix(hzA,hzB,u_pal_mix);
   bsM=mix(bsA,bsB,u_pal_mix);stM=mix(stA,stB,u_pal_mix);ntM=mix(ntA,ntB,u_pal_mix);hlM=mix(hlA,hlB,u_pal_mix);
  }
  // The sky (stars, nebula, galaxy) is world-fixed. pos is built from the
  // world normal and tangent, so dsky and osky are already world vectors:
  // sample the sky with them directly. The position angle then turns the
  // image against the sky instead of spinning the sky with it.
  vec3 dskyW=boostSky(ray,dsky),oskyW=osky;
  if(!captured){
   float starArc=0.; // lensed sky coordinates supply stretching, not a palette mask
   vec4 sky=skySample(dskyW);
   color+=trans*skyShift*(sky.a*stM*stars(dskyW,fw,starArc,normalize(vec2(-p.y,p.x)+vec2(1e-5)))+nM*ntM*sky.rgb*(BH_SCENE==4?u_zoom.z:1.)+bsM);
#if BH_SCENE==4
   // At galactic distances the lens has negligible angular extent. Start
   // the galaxy ray at the real observer, not the asymptote's closest point:
   // that point can lie inside the galaxy and discarded the near half.
   // Retain the actual observer at every distance; blend only directions.
   float galBlend=smoothstep(60.,400.,length(cam));
   color+=trans*galaxy(cam,normalize(mix(dskyW,ray,galBlend)));
#endif
  }else if(hzM>.001&&BH_SCENE!=0){
   // whitehole: hazy blue-gray vortex interior instead of a black disc
   float ang=atan(p.y,p.x);   // periodic sampling: no seam at +-pi
   float sw=noise(vec2(cos(ang)*1.8+impact*2.-u_time*.05,sin(ang)*1.8+impact*3.+u_time*.07));
   vec3 hz=mix(srgbLin(vec3(.12,.29,.36)),srgbLin(vec3(.24,.45,.52)),sw);
   color+=trans*hzM*hz*(.35+.65*sw)*.55*(1.-.6*smoothstep(1.2,2.6,impact));
  }


#if BH_SCENE==0 || BH_SCENE==4
  // Four radiance samples only at the critical pixel footprint. Dedicated
  // captures already jitter and average the full scene in linear light.
  if(u_dither>=-.5&&abs(impact-2.598076211353316)<1.5*criticalWidth){
   vec3 filtered=vec3(0.);
   for(int sampleIndex=0;sampleIndex<4;sampleIndex++){
    vec2 offset=vec2((sampleIndex&1)==0?-.25:.25,(sampleIndex&2)==0?-.25:.25);
    vec3 sampleRay=normalize(ray+offset.x*rayDx+offset.y*rayDy);
    vec3 emission,skyDir,skyOrigin;float transmission,b;bool hitHorizon;
    traceSingle(cam,sampleRay,diskN,right,closeFX,emission,transmission,hitHorizon,b,skyDir,skyOrigin);
    if(!hitHorizon){skyDir=boostSky(sampleRay,skyDir);vec4 sky=skySample(skyDir);emission+=transmission*skyShift*(sky.a*stM*stars(skyDir,fw,0.,vec2(1.,0.))+
       nM*ntM*sky.rgb*(BH_SCENE==4?u_zoom.z:1.)+bsM);}
    filtered+=emission;
   }
   color=filtered*.25;
  }
#endif
 }
#if BH_MULTI
 if(u_gw.x>0.){float g=max(gwGlow,0.);color+=(captured?.2:1.)*jet_tint()*g*g*.3;}
#else
#if BH_SCENE==3
 if(u_tde3.y>0.&&!captured)color+=trans*u_tde3.y*tdeStreamColor(3.)*.12*exp(-max(impact-2.6,0.)*.35);
#endif
#if BH_SCENE==3
 float jetK=.15*min(u_tde3.y,1.)*smoothstep(25.,45.,u_tde2.x);              // a TDE launches its jet only after the disruption
#else
 float jetK=1.;
#endif
 // A jet in front of the hole covers the shadow; behind it, it is hidden
 // (compared by distance along the ray: hole vs the jet's closest approach).
 // Depth order vs the DISK: the near lobe (tJet nearer than the first disk
 // crossing) is drawn at full radiance so the disk behind it does not wrongly
 // attenuate it; the far lobe is attenuated by the disk as before. Over the
 // shadow a lobe is visible when it is IN FRONT OF THE HOLE (never the disk
 // test alone: a lobe behind the hole must not cover the shadow just because
 // the ray misses the disk) or when enhanced occlusion is on, so an oblique
 // view keeps both lobes instead of losing one.
 if(BH_SCENE!=0&&BH_SCENE!=4&&u_jet>0.&&jetK>0.){
  float tHole=dot(-cam,ray),bj=dot(ray,jetAxis),dj=dot(ray,cam),ej=dot(jetAxis,cam);
  float tJet=(bj*ej-dj)/max(1.-bj*bj,1e-4);
  bool nearLobe=(tJet>0.&&tJet<tdisk);
  bool shadowVis=(tJet>0.&&tJet<tHole)||(u_enh>.5&&tJet<tHole-3.);
  vec3 jc=jet_lobes(cam,ray,jetAxis);
  if(nearLobe&&(!captured||shadowVis))color+=1.0*u_jet*jetK*u_jet_duty*1.2*jc;
  else if(!captured)color+=trans*u_jet*jetK*u_jet_duty*1.2*jc;
  else if(u_enh>.5&&tJet<tHole-3.)color+=1.0*u_jet*jetK*u_jet_duty*1.2*jc;
 }
 if(BH_SCENE!=0&&BH_SCENE!=4&&u_torus>0.){vec4 tr=torusAlong(cam,ray,diskN);float a=1.-exp(-tr.w*u_torus);color=color*(1.-a)+tr.rgb*u_torus*(1.-exp(-tr.w));}
#endif
 // Reinhard tonemap -> 1/2.2 gamma -> contrast toe + black point.
 // u_palette_contrast ~1.0 (gentle S-curve restoring Reinhard-flattened
 // contrast). 0.95-1.25 randomised per-launch.
 // Sparse local cells in three depth slabs. A particle is fixed in world
 // space; observer translation provides parallax. No per-particle CPU work.
 if(u_flight_view.w>.5 && u_flight_dust>1e-6){
  for(int layer=0;layer<3;layer++){
   float depth=1.5+float(layer)*1.6,cellSize=.23+float(layer)*.14;
   vec3 samplePos=cam+ray*depth,cell=floor(samplePos/cellSize);
   vec3 h=vec3(skyHash(cell),skyHash(cell+17.),skyHash(cell+39.));
   vec3 particle=(cell+.15+.7*h)*cellSize;
   vec3 delta=particle-cam;
   float along=dot(delta,ray);
   vec3 perp=delta-ray*along;
   vec3 motion=u_flight_velocity-ray*dot(u_flight_velocity,ray);
   float ml=length(motion),streak=flightStreak(u_flight_dust);
   if(ml>1e-6)perp-=motion/ml*clamp(dot(perp,motion/ml),-streak,streak);
   float width=.0025*depth;
   float point=exp(-dot(perp,perp)/(width*width));
   float fade=smoothstep(0.,.2,min(h.x,min(h.y,h.z)))*exp(-depth*.5);
   color+=vec3(.20,.22,.25)*point*fade*min(u_flight_dust,1.)*step(.86,h.x);
  }
 }
 color*=u_exposure;
 if(u_flight_view.w>.5){
  vec2 edge=(gl_FragCoord.xy/u_resolution-.5)*2.;
  color*=1.-u_flight_film.x*smoothstep(.3,1.5,dot(edge,edge));
  color*=1.+u_flight_film.y*(2.*skyHash(vec3(gl_FragCoord.xy,floor(u_time*24.)))-1.);
 }

 // Capture-quality mode averages supersamples in linear radiance and applies
 // the identical display transform (below) in C: output the radiance here.
 if(u_dither<-.5){fragColor=vec4(max(color,0.),1.);return;}
 if(u_tonemap>.5){
  color=color/(1.+color);
 }else{
  // Hue-preserving: compress luminance, scale all channels alike, keep the
  // hue when a channel would clip, and only the very hottest light fades to
  // a pale core. Per-channel Reinhard turned saturated hot regions chalky.
  float L=dot(max(color,0.),vec3(.2126,.7152,.0722));
  vec3 c=max(color,0.)/(1.+L);
  float mc=max(c.r,max(c.g,c.b));
  if(mc>1.)c/=mc;
  color=mix(c,vec3(1.),smoothstep(2.5,14.,L)*.55);
 }
 color=pow(max(color,0.),vec3(1./2.2));
 // Soft S-curve: (c-.5)*k+.5, then small black point + small white point lift.
 float k=clamp(u_palette_contrast,.85,1.35);
 color=(color-.5)*k+.5;
 color=max(color-vec3(.018),vec3(0));
 // +-0.5/255 dither against banding in the dark gradients (OLED panels).
 color+=u_dither*(fract(sin(dot(gl_FragCoord.xy,vec2(12.9898,78.233)))*43758.5453)-.5)/255.;
 fragColor=vec4(clamp(color*u_fade,0.,1.),1);
}
