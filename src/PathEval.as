namespace PathCam {

    float AngleLerp(float a, float b, float t) {
        float d = b - a;
        while (d > Math::PI)  d -= TAU;
        while (d < -Math::PI) d += TAU;
        return a + d * t;
    }

    vec3 CatmullRom(const vec3 &in p0, const vec3 &in p1, const vec3 &in p2, const vec3 &in p3, float t) {
        float t2 = t * t;
        float t3 = t2 * t;

        vec3 term1 = p1 * 2.0;
        vec3 term2 = (p2 - p0) * t;
        vec3 term3 = (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2;
        vec3 term4 = ((p3 - p0) + (p1 - p2) * 3.0) * t3;

        return 0.5 * (term1 + term2 + term3 + term4);
    }

    float WrapTime(float t, float len) {
        if (len <= 0.0) return t;
        t = t - len * Math::Floor(t / len);
        if (t < 0.0) t += len;
        return t;
    }

    float WrapAngle(float a) {
        while (a > Math::PI)  a -= TAU;
        while (a < -Math::PI) a += TAU;
        return a;
    }

    float MakeAngleContinuous(float last, float current) {
        float d = current - last;
        while (d > Math::PI)  d -= TAU;
        while (d < -Math::PI) d += TAU;
        return last + d;
    }

    CamKey EvalKeyframes(const CameraPath &in p, float t) {
        if (p.keys.Length == 0) {
            CamKey safe;
            safe.t = t;
            safe.target = vec3(0, 0, 0);
            safe.dist = 200.0;
            safe.h = 0.0;
            safe.v = 0.0;
            log("EvalKeyframes: keys.Length == 0; returning safe frame", LogLevel::Warn, 50, "MakeAngleContinuous");
            return safe;
        }

        float dur = Math::Max(0.0001, p.meta.duration);
        if (p.meta.loop) t = WrapTime(t, dur);
        else t = Math::Clamp(t, 0.0, dur);

        if (p.keys.Length == 1) {
            CamKey only = p.keys[0];
            only.t = t;
            return only;
        }

        int i1 = 0;
        for (uint i = 0; i < p.keys.Length - 1; i++) {
            if (t >= p.keys[i].t && t <= p.keys[i + 1].t) { i1 = int(i); break; }
            if (t > p.keys[p.keys.Length - 1].t) { i1 = int(p.keys.Length - 2); break; }
        }

        int i0 = Math::Max(0, i1 - 1);
        int i2 = Math::Min(i1 + 1, int(p.keys.Length - 1));
        int i3 = Math::Min(i1 + 2, int(p.keys.Length - 1));

        float span = Math::Max(0.0001, p.keys[i2].t - p.keys[i1].t);
        float u = Math::Clamp((t - p.keys[i1].t) / span, 0.0, 1.0);

        CamKey res;
        if (p.meta.interp == InterpMode::Linear) {
            res.target = Math::Lerp(p.keys[i1].target, p.keys[i2].target, u);
        } else {
            res.target = CatmullRom(p.keys[i0].target, p.keys[i1].target, p.keys[i2].target, p.keys[i3].target, u);
        }
        res.dist = Math::Lerp(p.keys[i1].dist, p.keys[i2].dist, u);
        res.h = AngleLerp(p.keys[i1].h, p.keys[i2].h, u);
        res.v = AngleLerp(p.keys[i1].v, p.keys[i2].v, u);
        res.t = t;
        return res;
    }

    float WrapDistance(float d, float len) {
        if (len <= 0.0) return d;
        d = d - len * Math::Floor(d / len);
        if (d < 0.0) d += len;
        return d;
    }

    vec3 SamplePolylineLinear(const FnPolyline &in pl, float distAlong) {
        if (pl.pts.Length == 0) return vec3();
        if (pl.pts.Length == 1) return pl.pts[0];

        float total = pl.totalLen;
        if (total <= 0.0) {
            float acc = 0.0;
            array<float> tmp;
            tmp.InsertLast(0.0);
            for (uint i = 1; i < pl.pts.Length; i++) {
                acc += (pl.pts[i] - pl.pts[i-1]).Length();
                tmp.InsertLast(acc);
            }
            if (pl.closed && pl.pts.Length > 1) acc += (pl.pts[0] - pl.pts[pl.pts.Length - 1]).Length();
            total = acc;
            if (total <= 0.0) return pl.pts[0];

            float D = distAlong;
            if (pl.closed) D = WrapDistance(D, total); else D = Math::Clamp(D, 0.0, total);

            uint last = pl.pts.Length - 1;
            if (!pl.closed) {
                for (uint i = 0; i < last; i++) {
                    float a = tmp[i];
                    float b = tmp[i + 1];
                    if (D >= a && D <= b) {
                        float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                        return Math::Lerp(pl.pts[i], pl.pts[i + 1], u);
                    }
                }
                return pl.pts[last];
            } else {
                for (uint i = 0; i < last; i++) {
                    float a = tmp[i];
                    float b = tmp[i + 1];
                    if (D >= a && D <= b) {
                        float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                        return Math::Lerp(pl.pts[i], pl.pts[i + 1], u);
                    }
                }
                float a = tmp[last];
                float b = total;
                if (D >= a && D <= b) {
                    float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                    return Math::Lerp(pl.pts[last], pl.pts[0], u);
                }
                return pl.pts[0];
            }
        }

        float D = distAlong;
        if (pl.closed) D = WrapDistance(D, total);
        else D = Math::Clamp(D, 0.0, total);

        uint lastIx = pl.pts.Length - 1;
        if (!pl.closed) {
            for (uint i = 0; i < lastIx; i++) {
                float a = pl.cumLen[i];
                float b = pl.cumLen[i + 1];
                if (D >= a && D <= b) {
                    float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                    return Math::Lerp(pl.pts[i], pl.pts[i + 1], u);
                }
            }
            return pl.pts[lastIx];
        } else {
            for (uint i = 0; i < lastIx; i++) {
                float a = pl.cumLen[i];
                float b = pl.cumLen[i + 1];
                if (D >= a && D <= b) {
                    float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                    return Math::Lerp(pl.pts[i], pl.pts[i + 1], u);
                }
            }
            float a = pl.cumLen[lastIx];
            float b = total;
            if (D >= a && D <= b) {
                float u = (b - a) > 1e-6 ? (D - a) / (b - a) : 0.0;
                return Math::Lerp(pl.pts[lastIx], pl.pts[0], u);
            }
            return pl.pts[0];
        }
    }

    vec2 DirToAngles(const vec3 &in dir) {
        vec3 nd = dir.Normalized();
        vec3 xz = vec3(nd.x, 0, nd.z);
        float lenxz = xz.Length();
        if (lenxz <= 1e-6) return vec2(0, 0);

        xz = xz / lenxz;
        float pitch = -Math::Asin(Math::Dot(nd, vec3(0, 1, 0)));
        float yaw = Math::Asin(Math::Dot(xz, vec3(1, 0, 0)));
        if (Math::Dot(xz, vec3(0, 0, -1)) > 0) yaw = -yaw - Math::PI;
        return vec2(yaw, pitch);
    }

    CamKey EvalFn(const CameraPath &in p, float t) {
        float dur = Math::Max(0.0001, p.meta.duration);
        if (p.meta.loop) t = WrapTime(t, dur);
        else t = Math::Clamp(t, 0.0, dur);

        CamKey res;
        res.t = t;

        string fn = p.fnName.ToLower();
        if (fn == "orbital_circle") {
            float dir = p.fnCircle.cw ? -1.0 : 1.0;
            float hDeg = p.fnCircle.startDeg + dir * p.fnCircle.degPerSec * t;
            res.h = hDeg * DEG2RAD;
            res.v = p.fnCircle.vDeg * DEG2RAD;
            res.target = p.fnCircle.center;
            res.dist = p.fnCircle.radius;

        } else if (fn == "orbital_helix") {
            float dir = p.fnHelix.cw ? -1.0 : 1.0;
            float hDeg = p.fnHelix.startDeg + dir * p.fnHelix.degPerSec * t;
            res.h = hDeg * DEG2RAD;
            float vDeg = Math::Lerp(p.fnHelix.vStartDeg, p.fnHelix.vEndDeg, t / dur);
            res.v = vDeg * DEG2RAD;
            res.target = p.fnHelix.center;
            res.dist = p.fnHelix.radius;

        } else if (fn == "target_polyline") {
            const FnPolyline pl = p.fnPolyline;
            if (pl.pts.Length == 0) {
                res.target = vec3(0, 0, 0);
                res.dist = 200.0;
                res.h = 0.0;
                res.v = 0.0;
                return res;
            }

            float total = Math::Max(1e-6, pl.totalLen);
            float D = pl.speed * t;
            float Dwrapped = p.meta.loop ? WrapDistance(D, total) : Math::Clamp(D, 0.0, total);
            float u = Dwrapped / total;

            float hOff = pl.heightCurve.Has()    ? pl.heightCurve.Eval01(u)    : pl.heightOffset;
            float dist = pl.distCurve.Has()      ? pl.distCurve.Eval01(u)      : pl.dist;
            float la   = pl.lookAheadCurve.Has() ? pl.lookAheadCurve.Eval01(u) : pl.lookAhead;

            vec3 tgt   = SamplePolylineLinear(pl, Dwrapped);
            vec3 ahead = SamplePolylineLinear(pl, Dwrapped + la);
            tgt.y   += hOff;
            ahead.y += hOff;

            vec3 dir = ahead - tgt;
            vec2 hv = DirToAngles(dir);

            res.target = tgt;
            res.dist   = dist;
            res.h      = hv.x;
            res.v      = hv.y;

        } else if (fn == "moving_orbit") {
            auto mo = p.fnMovingOrbit;
            const FnPolyline cpl = mo.center;

            float totalC = Math::Max(1e-6, cpl.totalLen);
            float Dc = cpl.speed * t;
            float DcWrapped = p.meta.loop ? WrapDistance(Dc, totalC) : Math::Clamp(Dc, 0.0, totalC);
            float uc = DcWrapped / totalC;

            vec3 center = SamplePolylineLinear(cpl, DcWrapped);

            float radius = mo.radiusCurve.Has() ? mo.radiusCurve.Eval01(uc) : mo.radius;
            float vDeg   = mo.vDegCurve.Has()   ? mo.vDegCurve.Eval01(uc)   : mo.vDeg;

            float dirSign = mo.cw ? -1.0 : 1.0;
            float hDeg    = mo.startDeg + dirSign * mo.degPerSec * t;

            res.h = hDeg * DEG2RAD;
            res.v = vDeg * DEG2RAD;
            res.target = center;
            res.dist = radius;

        } else {
            res.target = vec3(0, 0, 0);
            res.dist = 200.0;
            res.h = 0.0;
            res.v = 0.0;
        }

        return res;
    }

}