#include <metal_stdlib>
using namespace metal;

struct ReactiveUniforms {
  float2 resolution;
  float time;
  float deltaTime;
  float energy;
  float low;
  float mid;
  float high;
  float flux;
  float beat;
  float beatConfidence;
  float tempo;
  uint style;
  float motion;
  float seed;
  float padding;
  float4 baseColor;
  float4 accentColor;
  float4 sparkColor;
  float4 spectrum0;
  float4 spectrum1;
  float4 spectrum2;
  float4 spectrum3;
};

struct FullscreenOutput {
  float4 position [[position]];
  float2 uv;
};

struct ParticleOutput {
  float4 position [[position]];
  float pointSize [[point_size]];
  float4 color;
};

float hash11(float value) {
  return fract(sin(value * 127.1 + 311.7) * 43758.5453);
}

float2 hash21(float value) {
  return fract(sin(float2(value * 127.1, value * 269.5) + float2(311.7, 183.3)) * 43758.5453);
}

float noise21(float2 point) {
  float2 cell = floor(point);
  float2 fraction = fract(point);
  fraction = fraction * fraction * (3.0 - 2.0 * fraction);
  float a = hash11(dot(cell, float2(1.0, 57.0)));
  float b = hash11(dot(cell + float2(1.0, 0.0), float2(1.0, 57.0)));
  float c = hash11(dot(cell + float2(0.0, 1.0), float2(1.0, 57.0)));
  float d = hash11(dot(cell + 1.0, float2(1.0, 57.0)));
  return mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
}

float fbm(float2 point) {
  float result = 0.0;
  float amplitude = 0.52;
  for (uint octave = 0; octave < 4; octave++) {
    result += noise21(point) * amplitude;
    point = point * 2.03 + float2(9.1, 4.7);
    amplitude *= 0.48;
  }
  return result;
}

float spectrumAt(constant ReactiveUniforms &u, float position) {
  float scaled = clamp(position, 0.0, 0.999) * 16.0;
  uint index = uint(scaled);
  uint group = index / 4;
  uint lane = index % 4;
  if (group == 0) return u.spectrum0[lane];
  if (group == 1) return u.spectrum1[lane];
  if (group == 2) return u.spectrum2[lane];
  return u.spectrum3[lane];
}

float2 rotate2D(float2 point, float angle) {
  float s = sin(angle);
  float c = cos(angle);
  return float2(c * point.x - s * point.y, s * point.x + c * point.y);
}

vertex FullscreenOutput reactiveFullscreenVertex(uint vertexID [[vertex_id]]) {
  float2 position = vertexID == 0 ? float2(-1.0, -1.0)
    : (vertexID == 1 ? float2(3.0, -1.0) : float2(-1.0, 3.0));
  FullscreenOutput output;
  output.position = float4(position, 0.0, 1.0);
  output.uv = position * 0.5 + 0.5;
  return output;
}

fragment float4 reactiveBackgroundFragment(
  FullscreenOutput input [[stage_in]], constant ReactiveUniforms &u [[buffer(0)]]) {
  float2 uv = input.uv;
  float2 point = uv * 2.0 - 1.0;
  point.x *= u.resolution.x / max(u.resolution.y, 1.0);
  // Original cinematic camera rig: low frequencies push the stage toward the listener,
  // while the beat adds a brief roll and lateral parallax. `motion` is zero for
  // Reduce Motion / Low Power Mode, leaving a stable, readable composition.
  float cameraZoom = 1.0 + u.motion * (u.low * 0.075 + u.beat * 0.115);
  float cameraRoll = u.motion
    * (sin(u.time * 0.23 + u.seed * 5.0) * 0.032 + (u.high - 0.35) * u.beat * 0.060);
  point = rotate2D(point / cameraZoom, cameraRoll);
  point += u.motion * float2(
    sin(u.time * 0.17 + u.seed * 4.1) * (0.018 + u.mid * 0.020),
    cos(u.time * 0.13 + u.seed * 2.7) * (0.012 + u.low * 0.014));
  float vignette = smoothstep(1.45, 0.20, length(point * float2(0.70, 0.92)));
  float reactive = smoothstep(0.04, 0.82, clamp(u.energy, 0.0, 1.0));
  float3 ambient = mix(u.baseColor.rgb, u.accentColor.rgb, 0.18) * 0.055;
  float3 color = u.baseColor.rgb * (0.94 + reactive * 0.22) + ambient;

  if (u.style == 0) {
    float angle = atan2(point.y, point.x);
    float radius = length(point);
    float swirl = fbm(float2(angle * 1.7 + u.time * 0.055, radius * 3.1 - u.time * 0.09));
    float cloud = pow(smoothstep(0.28, 0.94, swirl), 1.7);
    color += u.accentColor.rgb * cloud * (0.26 + u.mid * 0.30);
    float core = exp(-radius * (2.6 - u.low * 0.45));
    color += mix(u.accentColor.rgb, u.sparkColor.rgb, 0.32) * core * (0.16 + u.low * 0.22);
    float ringRadius = 0.16 + (1.0 - u.beat) * 0.94;
    float ring = exp(-abs(radius - ringRadius) * 62.0) * u.beat;
    float ringEcho = exp(-abs(radius - ringRadius * 0.68) * 88.0) * u.beat * u.beat;
    color += u.sparkColor.rgb * (ring * 0.42 + ringEcho * 0.20);
    for (uint layer = 0; layer < 7; layer++) {
      float layerValue = float(layer);
      float depth = fract(layerValue / 7.0 + u.time * (0.025 + u.low * 0.085));
      float scale = mix(3.2, 14.0, depth);
      float2 starSpace = rotate2D(
        point * scale, u.time * (0.012 + u.mid * 0.025) * (layer % 2 == 0 ? 1.0 : -1.0));
      float2 cell = floor(starSpace);
      float cellSeed = dot(cell + layerValue * 31.7, float2(17.1, 91.7)) + u.seed * 101.0;
      float2 jitter = hash21(cellSeed) - 0.5;
      float2 delta = fract(starSpace) - 0.5 - jitter * 0.70;
      float size = mix(0.105, 0.035, depth) * (0.75 + u.high * 0.48);
      float star = smoothstep(size, 0.0, length(delta))
        * step(0.60 + depth * 0.22, hash11(cellSeed + 19.0));
      float twinkle = 0.68 + 0.32 * sin(u.time * (2.0 + hash11(cellSeed) * 6.0) + cellSeed);
      color += mix(u.accentColor.rgb, u.sparkColor.rgb, depth) * star * twinkle
        * (0.28 + u.energy * 0.38 + u.beat * 0.34);
    }
  } else if (u.style == 1) {
    float haze = fbm(point * 1.45 + float2(u.time * 0.025, -u.time * 0.018));
    color += u.accentColor.rgb * pow(haze, 2.4) * (0.11 + u.mid * 0.14);
    for (uint layer = 0; layer < 3; layer++) {
      float layerValue = float(layer);
      float baseline = -0.52 + layerValue * 0.42;
      float wave = sin(point.x * (1.25 + layerValue * 0.22) + u.time * (0.36 + layerValue * 0.08)
        + u.seed * 6.28 + layerValue) * (0.11 + u.low * 0.14 + u.beat * 0.055);
      wave += sin(point.x * 2.8 - u.time * 0.22 + layerValue * 2.1) * u.mid * 0.065;
      float distanceToRibbon = abs(point.y - baseline - wave);
      float ribbon = exp(-distanceToRibbon * (13.0 - u.mid * 3.0));
      float edge = exp(-distanceToRibbon * 52.0);
      float3 ribbonColor = mix(u.accentColor.rgb, u.sparkColor.rgb, layerValue * 0.22);
      color += ribbonColor * ribbon * (0.13 + u.energy * 0.105);
      color += u.sparkColor.rgb * edge * (0.040 + u.high * 0.075 + u.beat * 0.045);
    }
  } else {
    float radius = length(point);
    float angle = atan2(point.y, point.x);
    float halo = exp(-abs(radius - (0.46 + u.low * 0.070 + u.beat * 0.055)) * 14.0);
    float inner = exp(-radius * 3.6);
    float spokes = pow(max(0.0, sin(angle * 9.0 + u.time * 0.24 + radius * 10.0)), 9.0);
    color += u.accentColor.rgb * halo * (0.15 + u.energy * 0.15 + u.beat * 0.08);
    color += u.sparkColor.rgb * inner * (0.085 + u.mid * 0.08);
    color += u.sparkColor.rgb * spokes * halo * u.high * 0.055;
    for (uint node = 0; node < 14; node++) {
      float nodeValue = float(node);
      float orbit = 0.36 + float(node % 3) * 0.19 + u.low * 0.070 + u.beat * 0.025;
      float nodeAngle = nodeValue * 2.39996 + u.time * (0.14 + float(node % 3) * 0.040);
      float2 nodePosition = float2(cos(nodeAngle) * orbit, sin(nodeAngle) * orbit * 0.52);
      nodePosition = rotate2D(nodePosition, -0.34 + float(node % 3) * 0.21);
      float nodeGlow = exp(-length(point - nodePosition) * (42.0 - u.high * 8.0));
      color += mix(u.accentColor.rgb, u.sparkColor.rgb, float(node % 4) / 3.0)
        * nodeGlow * (0.22 + u.energy * 0.26 + u.beat * 0.16);
    }
  }

  color *= 0.58 + vignette * 0.58;
  color += u.sparkColor.rgb * u.beat * 0.016 * vignette;
  return float4(pow(max(color, 0.0), float3(0.92)), 1.0);
}

vertex ParticleOutput reactiveParticleVertex(
  uint vertexID [[vertex_id]], constant ReactiveUniforms &u [[buffer(0)]]) {
  float id = float(vertexID) + u.seed * 10003.0;
  float h0 = hash11(id * 1.013);
  float h1 = hash11(id * 2.171 + 9.0);
  float h2 = hash11(id * 3.733 + 17.0);
  float aspect = u.resolution.y / max(u.resolution.x, 1.0);
  float2 projected = 0.0;
  float pointSize = 1.0;
  float brightness = 0.4;
  float depthFade = 1.0;

  if (u.style == 0) {
    float travel = u.time * (0.080 + u.low * 0.300 + u.flux * 0.085) + u.beat * 0.055;
    float depthPhase = fract(h0 + travel);
    float depth = 0.16 + depthPhase * 6.4;
    float angle = h1 * 6.28318 + u.time * (0.025 + u.mid * 0.055) * (h2 > 0.5 ? 1.0 : -1.0);
    float radius = 0.12 + pow(h2, 0.72) * 3.65;
    float2 plane = float2(cos(angle), sin(angle)) * radius;
    float cameraRoll = sin(u.time * 0.17 + u.seed * 4.0) * 0.038 + u.beat * 0.052;
    plane = rotate2D(plane, cameraRoll);
    float cameraPush = 1.0 + u.low * 0.075 + u.beat * 0.16;
    projected = plane / depth * cameraPush;
    projected.y /= aspect;
    pointSize = 2.0 + pow(1.0 - depthPhase, 2.2) * (15.0 + u.high * 8.0 + u.beat * 5.0);
    brightness = (0.42 + h1 * 0.88) * (0.72 + u.energy * 0.92 + u.beat * 0.18);
    depthFade = smoothstep(0.0, 0.08, depthPhase)
      * (1.0 - smoothstep(0.72, 1.0, depthPhase));
  } else if (u.style == 1) {
    uint layer = vertexID % 3;
    float layerValue = float(layer);
    float path = fract(float(vertexID / 3) / 2048.0 + h0 * 0.032 + u.time * (0.018 + u.high * 0.012));
    float x = mix(-2.3, 2.3, path);
    float baseline = -0.55 + layerValue * 0.44;
    float y = baseline
      + sin(x * (1.38 + layerValue * 0.20) + u.time * (0.38 + layerValue * 0.09)
        + u.seed * 6.28 + layerValue) * (0.12 + u.low * 0.17 + u.beat * 0.06)
      + sin(x * 3.0 - u.time * 0.24 + h1) * (0.020 + u.mid * 0.090);
    y += (h2 - 0.5) * (0.045 + u.mid * 0.12);
    float depth = 1.0 + layerValue * 0.20;
    projected = float2(x / depth, y / depth);
    projected.y /= aspect;
    pointSize = 1.3 + u.high * 4.2 + h1 * 1.8 + u.beat * 2.0;
    brightness = (0.34 + u.energy * 0.72 + u.beat * 0.16) * (0.62 + h2 * 0.58);
    depthFade = sin(path * 3.14159);
  } else {
    float a = h0 * 6.28318 + u.time * (0.11 + u.mid * 0.08);
    float b = h1 * 6.28318 + u.time * (h2 > 0.5 ? 0.08 : -0.065);
    float majorRadius = 0.68 + u.low * 0.12 + u.beat * 0.075;
    float minorRadius = 0.18 + u.mid * 0.16 + u.beat * 0.035;
    float3 point3D = float3(
      (majorRadius + minorRadius * cos(b)) * cos(a),
      minorRadius * sin(b),
      (majorRadius + minorRadius * cos(b)) * sin(a));
    float tilt = -0.54 + sin(u.time * 0.09) * 0.08;
    point3D.yz = rotate2D(point3D.yz, tilt);
    point3D.xz = rotate2D(point3D.xz, u.time * 0.045);
    float scatter = smoothstep(0.56, 1.0, u.high + u.beat * 0.30) * smoothstep(0.78, 1.0, h2);
    point3D += normalize(point3D + 0.001) * scatter * (0.18 + u.flux * 0.38 + u.beat * 0.14);
    float depth = 2.25 + point3D.z;
    projected = point3D.xy / depth * (2.0 + u.low * 0.10 + u.beat * 0.16);
    projected.y /= aspect;
    pointSize = 1.25 + (1.0 - h2) * 3.4 + u.high * 3.2 + u.beat * 1.8;
    brightness = 0.38 + u.energy * 0.70 + scatter * 0.42 + u.beat * 0.14;
    depthFade = smoothstep(1.2, 3.2, depth);
  }

  float colorMix = clamp(h1 * 0.72 + u.high * 0.24, 0.0, 1.0);
  float3 particleColor = mix(u.accentColor.rgb, u.sparkColor.rgb, colorMix);
  ParticleOutput output;
  output.position = float4(projected, 0.0, 1.0);
  output.pointSize = clamp(pointSize, 1.0, 24.0);
  output.color = float4(particleColor * brightness, depthFade);
  return output;
}

fragment float4 reactiveParticleFragment(
  ParticleOutput input [[stage_in]], float2 pointCoordinate [[point_coord]],
  constant ReactiveUniforms &u [[buffer(0)]]) {
  float2 centered = pointCoordinate - 0.5;
  float radius = length(centered);
  if (radius > 0.5) discard_fragment();
  float core = smoothstep(0.50, 0.0, radius);
  float glow = exp(-radius * radius * 10.0);
  float alpha = (core * 0.78 + glow * 0.46) * input.color.a;
  return float4(input.color.rgb * (0.76 + u.beat * 0.34), alpha);
}
