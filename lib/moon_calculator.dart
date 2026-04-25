import 'dart:math';

class MoonPosition {
  final double azimuth;   // degrees from North clockwise
  final double altitude;  // degrees above horizon
  final double distance;  // km

  MoonPosition({
    required this.azimuth,
    required this.altitude,
    required this.distance,
  });

  bool get isAboveHorizon => altitude > 0;
}

class MoonCalculator {
  // Calculate moon position for given lat/lng and time
  static MoonPosition calculate(double lat, double lng, DateTime dateTime) {
    final jd = _julianDate(dateTime);
    final t = (jd - 2451545.0) / 36525.0; // Julian centuries from J2000

    // Moon's orbital elements
    double L = _normalize(218.3164477 + 481267.88123421 * t); // mean longitude
    double M = _normalize(357.5291092 + 35999.0502909 * t);   // sun mean anomaly
    double Mprime = _normalize(134.9633964 + 477198.8675055 * t); // moon mean anomaly
    double D = _normalize(297.8501921 + 445267.1114034 * t);  // moon mean elongation
    double F = _normalize(93.2720950 + 483202.0175233 * t);   // moon argument of latitude

    // Convert to radians
    final Lr = L * pi / 180;
    final Mr = M * pi / 180;
    final Mpr = Mprime * pi / 180;
    final Dr = D * pi / 180;
    final Fr = F * pi / 180;

    // Longitude correction (simplified)
    double dL = 6288774 * sin(Mpr)
        + 1274027 * sin(2 * Dr - Mpr)
        + 658314 * sin(2 * Dr)
        + 213618 * sin(2 * Mpr)
        - 185116 * sin(Mr)
        - 114332 * sin(2 * Fr)
        + 58793 * sin(2 * Dr - 2 * Mpr)
        + 57066 * sin(2 * Dr - Mr - Mpr)
        + 53322 * sin(2 * Dr + Mpr)
        + 45758 * sin(2 * Dr - Mr);

    // Latitude correction (simplified)
    double dB = 5128122 * sin(Fr)
        + 280602 * sin(Mpr + Fr)
        + 277693 * sin(Mpr - Fr)
        + 173237 * sin(2 * Dr - Fr)
        + 55413 * sin(2 * Dr - Mpr + Fr)
        + 46271 * sin(2 * Dr - Mpr - Fr)
        + 32573 * sin(2 * Dr + Fr);

    // Distance correction
    double dR = -20905355 * cos(Mpr)
        - 3699111 * cos(2 * Dr - Mpr)
        - 2955968 * cos(2 * Dr)
        - 569925 * cos(2 * Mpr)
        + 246158 * cos(2 * Dr - 2 * Mpr)
        - 204586 * cos(Mr);

    // Ecliptic coordinates
    double lambda = L + dL / 1000000.0; // ecliptic longitude
    double beta = dB / 1000000.0;        // ecliptic latitude
    double delta = 385000.56 + dR / 1000.0; // distance km

    // Convert to equatorial coordinates
    final e = (23.439291111 - 0.013004167 * t) * pi / 180; // obliquity
    final lambdaR = lambda * pi / 180;
    final betaR = beta * pi / 180;

    final sinDec = sin(betaR) * cos(e) + cos(betaR) * sin(e) * sin(lambdaR);
    final dec = asin(sinDec); // declination

    final y = sin(lambdaR) * cos(e) - tan(betaR) * sin(e);
    final x = cos(lambdaR);
    final ra = atan2(y, x); // right ascension

    // Greenwich Mean Sidereal Time
    final gmst = _normalize(280.46061837 + 360.98564736629 * (jd - 2451545.0)
        + 0.000387933 * t * t) * pi / 180;

    // Local Sidereal Time
    final lst = gmst + lng * pi / 180;

    // Hour angle
    final ha = lst - ra;

    // Convert to horizontal coordinates
    final latR = lat * pi / 180;
    final sinAlt = sin(latR) * sin(dec) + cos(latR) * cos(dec) * cos(ha);
    final altitude = asin(sinAlt) * 180 / pi;

    final cosAz = (sin(dec) - sin(latR) * sinAlt) / (cos(latR) * cos(asin(sinAlt)));
    double azimuth = acos(cosAz.clamp(-1.0, 1.0)) * 180 / pi;
    if (sin(ha) > 0) azimuth = 360 - azimuth;

    return MoonPosition(
      azimuth: azimuth,
      altitude: altitude,
      distance: delta,
    );
  }

  static double _julianDate(DateTime dt) {
    final utc = dt.toUtc();
    int y = utc.year;
    int m = utc.month;
    final d = utc.day + utc.hour / 24.0 + utc.minute / 1440.0 + utc.second / 86400.0;
    if (m <= 2) { y--; m += 12; }
    final a = (y / 100).floor();
    final b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d + b - 1524.5;
  }

  static double _normalize(double deg) {
    double d = deg % 360;
    return d < 0 ? d + 360 : d;
  }
}
