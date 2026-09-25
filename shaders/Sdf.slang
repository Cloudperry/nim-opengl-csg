module Sdf;

public interface IFloatSdfScene {
	static float sdf(float3 p);
}
public interface IColoredFloatSdfScene : IFloatSdfScene {
	static float3 surfaceColor(float3 p);
}
public interface IDifferentiableFloatSdfScene {
	[Differentiable]
	static float sdf(float3 p);
}

// SDF shapes and CSG ops from https://iquilezles.org/articles/distfunctions/

// Sphere - exact
[Differentiable]
public T sdSphere<T>(vector<T, 3> p, T r) where T : __BuiltinFloatingPointType {
	return length(p) - r;
}

// Box - exact
[Differentiable]
public T sdBox<T>(vector<T, 3> p, vector<T, 3> halfExtent) where T : __BuiltinFloatingPointType {
  vector<T, 3> q = abs(p) - halfExtent;
  return length(max(q, (T)0.0)) + min(max(q.x, max(q.y, q.z)), (T)0.0); // Make a varargs max for max chains like this?
}

// Round box - exact
[Differentiable]
public T sdRoundBox<T>(vector<T, 3> p, vector<T, 3> halfExtent, T r) where T : __BuiltinFloatingPointType {
  vector<T, 3> q = abs(p) - halfExtent + r;
  return length(max(q, (T)0.0)) + min(max(q.x, max(q.y, q.z)), (T)0.0) - r;
}

// Box frame - exact
[Differentiable]
public T sdBoxFrame<T>(vector<T, 3> p, vector<T, 3> b, T e) where T : __BuiltinFloatingPointType {
  p = abs(p) - b;
  vector<T, 3> q = abs(p+e)-e;
  return min(min(
      length(max(vector<T, 3>(p.x,q.y,q.z), (T)0.0))+min(max(p.x,max(q.y,q.z)), (T)0.0),
      length(max(vector<T, 3>(q.x,p.y,q.z), (T)0.0))+min(max(q.x,max(p.y,q.z)), (T)0.0)),
      length(max(vector<T, 3>(q.x,q.y,p.z), (T)0.0))+min(max(q.x,max(q.y,p.z)), (T)0.0));
}

// Cone - exact
[Differentiable]
public T sdCone<T>(vector<T, 3> p, vector<T, 2> c, T h) where T : __BuiltinFloatingPointType {
  // c is the sin/cos of the angle, h is height
  // Alternatively pass q instead of (c,h),
  // which is the point at the base in 2D
  vector<T, 2> q = h*vector<T, 2>(c.x/c.y,-(T)1.0);

  vector<T, 2> w = vector<T, 2>( length(p.xz), p.y );
  vector<T, 2> a = w - q*clamp( dot(w,q)/dot(q,q), (T)0.0, (T)1.0);
  vector<T, 2> b = w - q*vector<T, 2>( clamp( w.x/q.x, (T)0.0, (T)1.0 ), (T)1.0 );
  T k = (T)sign( q.y );
  T d = min(dot( a, a ),dot(b, b));
  T s = max( k*(w.x*q.y-w.y*q.x),k*(w.y-q.y)  );
  return sqrt(d) * (T)sign(s);
}

// Hexagonal prism - exact
[Differentiable]
public T sdHexPrism<T>(vector<T, 3> p, vector<T, 2> h) where T : __BuiltinFloatingPointType {
  const vector<T, 3> k = vector<T, 3>((T) -0.8660254, (T) 0.5, (T) 0.57735);
  p = abs(p);
  p.xy -= (T) 2.0 * min(dot(k.xy, p.xy), (T) 0.0) * k.xy;
  vector<T, 2> d = vector<T, 2>(
       length(p.xy-vector<T, 2>(clamp(p.x,-k.z*h.x,k.z*h.x), h.x)) * (T) sign(p.y-h.x),
       p.z-h.y );
  return min(max(d.x,d.y), (T) 0.0) + length(max(d, (T) 0.0));
}

// Triangular prism - bound
[Differentiable]
public T sdTriPrism<T>( vector<T, 3> p, vector<T, 2> h ) where T : __BuiltinFloatingPointType {
  vector<T, 3> q = abs(p);
  return max(q.z -h.y , max(q.x * (T) 0.866025 + p.y * (T) 0.5, -p.y) -h.x * (T) 0.5);
}

// Arbitrary capsule - exact
[Differentiable]
public T sdCapsule<T>( vector<T, 3> p, vector<T, 3> a, vector<T, 3> b, T r ) where T : __BuiltinFloatingPointType {
  vector<T, 3> pa = p - a, ba = b - a;
  T h = clamp( dot(pa,ba) / dot(ba,ba), (T) 0.0, (T) 1.0 );
  return length( pa - ba*h ) - r;
}

// Arbitrary capped cylinder - exact
[Differentiable]
public T sdCappedCylinder<T>(vector<T, 3> p, vector<T, 3> a, vector<T, 3> b, T r) where T : __BuiltinFloatingPointType {
  vector<T, 3> ba = b - a;
  vector<T, 3> pa = p - a;
  T baba = dot(ba, ba);
  T paba = dot(pa, ba);
  T x = length(pa * baba - ba * paba) - r * baba;
  T y = abs(paba - baba * (T)0.5) - baba * (T)0.5;
  T x2 = x * x;
  T y2 = y * y * baba;
  T d = (max(x, y) < (T)0.0) ? -min(x2, y2) : (((x > (T)0.0) ? x2 : (T)0.0) + ((y > (T)0.0) ? y2 : (T)0.0));
  return (T)sign(d) * sqrt(abs(d)) / baba;
}

// Rounded cylinder - exact
[Differentiable]
public T sdRoundedCylinder<T>( vector<T, 3> p, T ra, T rb, T h ) where T : __BuiltinFloatingPointType {
  vector<T, 2> d = vector<T, 2>( length(p.xz) - (T) 2.0*ra+rb, abs(p.y) - h );
  return min(max(d.x,d.y), (T) 0.0) + length(max(d , (T) 0.0)) - rb;
}

// Arbitrary capped cone - exact
[Differentiable]
public T sdCappedCone<T>( vector<T, 3> p, vector<T, 3> a, vector<T, 3> b, T ra, T rb ) where T : __BuiltinFloatingPointType {
  T rba  = rb-ra;
  T baba = dot(b-a,b-a);
  T papa = dot(p-a,p-a);
  T paba = dot(p-a,b-a)/baba;
  T x = sqrt( papa - paba*paba*baba );
  T cax = max((T) 0.0,x-((paba < (T) 0.5)?ra:rb));
  T cay = abs(paba - (T) 0.5) - (T) 0.5;
  T k = rba*rba + baba;
  T f = clamp( (rba*(x-ra)+paba*baba)/k, (T) 0.0, (T) 1.0 );
  T cbx = x-ra - f*rba;
  T cby = paba - f;
  T s = (cbx < (T) 0.0 && cay < (T) 0.0) ? (T) -1.0 : (T) 1.0;
  return s*sqrt( min(cax*cax + cay*cay*baba,
                     cbx*cbx + cby*cby*baba) );
}

// Cut sphere - exact
[Differentiable]
public T sdCutSphere<T>( vector<T, 3> p, T r, T h ) where T : __BuiltinFloatingPointType {
  T w = sqrt(r*r-h*h);

  vector<T, 2> q = vector<T, 2>( length(p.xz), p.y );
  T s = max( (h-r)*q.x*q.x+w*w*(h+r - (T) 2.0 * q.y), h*q.x-w*q.y );
  return (s < (T) 0.0) ? length(q)-r :
         (q.x<w) ? h - q.y     :
                   length(q-vector<T, 2>(w,h));
}

// Octahedron - exact
[Differentiable]
public T sdOctahedron<T>( vector<T, 3> p, T s ) where T : __BuiltinFloatingPointType {
  p = abs(p);
  T m = p.x+p.y+p.z-s;
  vector<T, 3> q;
       if( (T) 3.0 * p.x < m ) q = p.xyz;
  else if( (T) 3.0 * p.y < m ) q = p.yzx;
  else if( (T) 3.0 * p.z < m ) q = p.zxy;
  else return m * (T) 0.57735027;

  T k = clamp((T) 0.5*(q.z-q.y+s), (T) 0.0,s);
  return length(vector<T, 3>(q.x,q.y-s+k,q.z-k));
}

[Differentiable]
// Pyramid - exact
// NOTE: Be careful with this pyramid. It doesn't have a bottom quad, so looking in from the bottom produces completely broken normals.
public T sdPyramid<T>(vector<T, 3> p, T h) where T : __BuiltinFloatingPointType {
  T m2 = h * h + (T)0.25;

  p.xz = abs(p.xz);
  p.xz = (p.z > p.x) ? p.zx : p.xz;
  p.xz -= (T)0.5;

  vector<T, 3> q = vector<T, 3>(p.z, h * p.y - (T)0.5 * p.x, h * p.x + (T)0.5 * p.y);

  T s = max(-q.x, (T)0.0);
  T t = clamp((q.y - (T)0.5 * p.z) / (m2 + (T)0.25), (T)0.0, (T)1.0);

  T a = m2 * (q.x + s) * (q.x + s) + q.y * q.y;
  T b = m2 * (q.x + (T)0.5 * t) * (q.x + (T)0.5 * t) + (q.y - m2 * t) * (q.y - m2 * t);

  T d2 = min(q.y, -q.x * m2 - q.y * (T)0.5) > (T)0.0 ? (T)0.0 : min(a, b);

  return sqrt((d2 + q.z * q.z) / m2) * (T)sign(max(q.z, -p.y));
}

[Differentiable]
T dot2<T>(vector<T, 3> v) where T : __BuiltinFloatingPointType { return dot(v, v); }
// Triangle - exact
[Differentiable]
public T udTriangle<T>( vector<T, 3> p, vector<T, 3> a, vector<T, 3> b, vector<T, 3> c ) where T : __BuiltinFloatingPointType {
  vector<T, 3> ba = b - a; vector<T, 3> pa = p - a;
  vector<T, 3> cb = c - b; vector<T, 3> pb = p - b;
  vector<T, 3> ac = a - c; vector<T, 3> pc = p - c;
  vector<T, 3> nor = cross( ba, ac );

  return sqrt(
    ((T) sign(dot(cross(ba,nor),pa)) +
     (T) sign(dot(cross(cb,nor),pb)) +
     (T) sign(dot(cross(ac,nor),pc)) < (T) 2.0)
     ?
     min( min(
     dot2(ba*clamp(dot(ba,pa)/dot2(ba), (T) 0.0, (T) 1.0)-pa),
     dot2(cb*clamp(dot(cb,pb)/dot2(cb), (T) 0.0, (T) 1.0)-pb) ),
     dot2(ac*clamp(dot(ac,pc)/dot2(ac), (T) 0.0, (T) 1.0)-pc) )
     :
     dot(nor,pa)*dot(nor,pa)/dot2(nor) );
}

// Quad - exact
[Differentiable]
public T udQuad<T>( vector<T, 3> p, vector<T, 3> a, vector<T, 3> b, vector<T, 3> c, vector<T, 3> d ) where T : __BuiltinFloatingPointType {
  vector<T, 3> ba = b - a; vector<T, 3> pa = p - a;
  vector<T, 3> cb = c - b; vector<T, 3> pb = p - b;
  vector<T, 3> dc = d - c; vector<T, 3> pc = p - c;
  vector<T, 3> ad = a - d; vector<T, 3> pd = p - d;
  vector<T, 3> nor = cross( ba, ad );


  return sqrt(
    ((T) sign(dot(cross(ba,nor),pa)) +
     (T) sign(dot(cross(cb,nor),pb)) +
     (T) sign(dot(cross(dc,nor),pc)) +
     (T) sign(dot(cross(ad,nor),pd)) < (T) 3.0)
     ?
     min( min( min(
     dot2(ba*clamp(dot(ba,pa)/dot2(ba), (T) 0.0, (T) 1.0)-pa),
     dot2(cb*clamp(dot(cb,pb)/dot2(cb), (T) 0.0, (T) 1.0)-pb) ),
     dot2(dc*clamp(dot(dc,pc)/dot2(dc), (T) 0.0, (T) 1.0)-pc) ),
     dot2(ad*clamp(dot(ad,pd)/dot2(ad), (T) 0.0, (T) 1.0)-pd) )
     :
     dot(nor,pa)*dot(nor,pa)/dot2(nor)
	);
}

// Plane - exact
// Idk why this is called a plane when it is more of a half-space. The other side of the plane is always inside, making the volume extend out to infinity on that side.
[Differentiable]
public T sdPlane<T>( vector<T, 3> p, vector<T, 3> n, T h ) where T : __BuiltinFloatingPointType {
  return dot(p, n) + h; // Normal vector n must be normalized
}

[Differentiable]
public T opUnion<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	return min(d1, d2);
}

// Exact Euclidean CSG subtraction: cuts d1 from d2.
// Evaluates the exterior distance field with Euclidean Pythagorean corner term length(max(d, 0.0)),
// preserving true Euclidean distances (|∇f| = 1) in exterior space around cut corners and seams.
[Differentiable]
public T opSubtraction<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	vector<T, 2> d = vector<T, 2>(-d1, d2);
	return min(max(d.x, d.y), (T)0.0) + length(max(d, (T)0.0));
}

// Approximate CSG subtraction using naive max(-d1, d2).
// Preserves metric distance inside the cut (d < 0), but distorts exterior distance (d > 0) near
// concave corners and edges by omitting the Euclidean corner radius, which causes non-Lipschitz
// gradient steps and severe penumbra banding / artifacts during raymarching and soft shadow tracing.
[Differentiable]
public T opSubtractionApprox<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	return max(-d1, d2);
}

// Exact Euclidean CSG intersection of d1 and d2.
// Includes the corner term length(max(d, 0.0)) to preserve exact Euclidean distance
// outside intersecting boundaries and along the intersection seam.
[Differentiable]
public T opIntersection<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	vector<T, 2> d = vector<T, 2>(d1, d2);
	return min(max(d.x, d.y), (T)0.0) + length(max(d, (T)0.0));
}

// Approximate CSG intersection using naive max(d1, d2).
// Preserves interior distances but under-estimates exterior Euclidean distance near the intersection seam.
[Differentiable]
public T opIntersectionApprox<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	return max(d1, d2);
}

[Differentiable]
public T opXor<T>(T d1, T d2) where T : __BuiltinFloatingPointType {
	return max(min(d1, d2), -max(d1, d2));
}

[Differentiable]
public T opSmoothUnion<T>( T d1, T d2, T k ) where T : __BuiltinFloatingPointType {
	k *= (T) 4.0;
	T h = max(k-abs(d1-d2), (T) 0.0);
	return min(d1, d2) - h*h * (T) 0.25/k;
}

[Differentiable]
public T opSmoothSubtraction<T>( T d1, T d2, T k ) where T : __BuiltinFloatingPointType {
	return -opSmoothUnion(d1,-d2,k);
}

[Differentiable]
public T opSmoothIntersection<T>( T d1, T d2, T k ) where T : __BuiltinFloatingPointType {
	return -opSmoothUnion(-d1,-d2,k);
}

// Quadratic polynomial smooth min
public float smin(float a, float b, float k) {
	k *= 4.0;
	float h = max( k-abs(a-b), 0.0 )/k;
	return min(a,b) - h*h*k*(1.0/4.0);
}

// TODO: Add rotation/translation and scaling (need function pointers or a way to pass functions as args,
// maybe https://code4k.blogspot.com/2011/11/advanced-hlsl-using-closures-and.html). Mirroring, repetition,
// displacement, twisting and bending also need functions as args.

public struct MatIAndDist {
  public uint matI;
  public float dist;
  __init() {
    matI = 0;
    dist = float.maxValue;
  }
}

MatIAndDist neg(MatIAndDist md1) {
  var negation = md1;
  negation.dist = -negation.dist;
  return negation;
}

public MatIAndDist min(MatIAndDist md1, MatIAndDist md2) {
  if (md1.dist <= md2.dist) {
    return md1;
  } else {
    return md2;
  }
}

public MatIAndDist max(MatIAndDist md1, MatIAndDist md2) {
  if (md1.dist >= md2.dist) {
    return md1;
  } else {
    return md2;
  }
}

public MatIAndDist opUnion(MatIAndDist md1, MatIAndDist md2) { return min(md1, md2); }
public MatIAndDist opSubtraction(MatIAndDist md1, MatIAndDist md2) { return max(neg(md1), md2); }
public MatIAndDist opIntersection(MatIAndDist md1, MatIAndDist md2) { return max(md1, md2); }
public MatIAndDist opXor(MatIAndDist md1, MatIAndDist md2) { return max(min(md1, md2), neg(max(md1, md2))); }

// TODO: Replace this placeholder smooth union with one that actually blends the material with the same smoothing curve.
// Or at the very least use material from opUnion.
public MatIAndDist opSmoothUnion(MatIAndDist md1, MatIAndDist md2, float k) {
  k *= 4.0;
  float h = max(k - abs(md1.dist - md2.dist), 0.0);
  float dist = min(md1.dist, md2.dist) - h * h * 0.25 / k;
  var res = md1;
  res.dist = dist;
  return res;
}
public MatIAndDist opSmoothSubtraction(MatIAndDist md1, MatIAndDist md2, float k) {
  return neg(opSmoothUnion(md1, neg(md2), k));
}
public MatIAndDist opSmoothIntersection(MatIAndDist md1, MatIAndDist md2, float k) {
  return neg(opSmoothUnion(neg(md1), neg(md2), k));
}
