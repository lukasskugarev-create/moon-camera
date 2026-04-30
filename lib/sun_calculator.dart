import 'dart:math';

class SunPosition {
  final double azimuth;   // degrees from North clockwise
  final double altitude;  // degrees above horizon
  
  SunPosition({required this.azimuth, required this.altitude});
  
  bool get isAboveHorizon => altitude > 0;
}

class SunCalculator {
  static SunPosition calculate(double lat, double lng, DateTime dateTime) {
    final utc = dateTime.toUtc();
    
    // Julian date
    final jd = _julianDate(utc);
    final n = jd - 2451545.0;
    
    // Mean longitude and mean anomaly
    double L = _normalize(280.460 + 0.9856474 * n);
    double g = _normalize(357.528 + 0.9856003 * n) * pi / 180;
    
    // Ecliptic longitude
    double lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * pi / 180;
    
    // Obliquity of ecliptic
    double epsilon = (23.439 - 0.0000004 * n) * pi / 180;
    
    // Right ascension and declination
    double sinDec = sin(epsilon) * sin(lambda);
    double dec = asin(sinDec);
    
    double y = cos(epsilon) * sin(lambda);
    double x = cos(lambda);
    double ra = atan2(y, x);
    
    // Greenwich Mean Sidereal Time
    double gmst = _normalize(280.46061837 + 360.98564736629 * (jd - 2451545.0)) * pi / 180;
    
    // Local Sidereal Time
    double lst = gmst + lng * pi / 180;
    
    // Hour angle
    double ha = lst - ra;
    
    // Horizontal coordinates
    double latR = lat * pi / 180;
    double sinAlt = sin(latR) * sin(dec) + cos(latR) * cos(dec) * cos(ha);
    double altitude = asin(sinAlt.clamp(-1.0, 1.0)) * 180 / pi;
    
    double cosAz = (sin(dec) - sin(latR) * sinAlt) / (cos(latR) * cos(asin(sinAlt.clamp(-1.0, 1.0))));
    double azimuth = acos(cosAz.clamp(-1.0, 1.0)) * 180 / pi;
    if (sin(ha) > 0) azimuth = 360 - azimuth;
    
    return SunPosition(azimuth: azimuth, altitude: altitude);
  }
  
  static double _julianDate(DateTime dt) {
    int y = dt.year;
    int m = dt.month;
    double d = dt.day + dt.hour / 24.0 + dt.minute / 1440.0 + dt.second / 86400.0;
    if (m <= 2) { y--; m += 12; }
    int a = (y / 100).floor();
    int b = 2 - a + (a / 4).floor();
    return (365.25 * (y + 4716)).floor() + (30.6001 * (m + 1)).floor() + d + b - 1524.5;
  }
  
  static double _normalize(double deg) {
    double d = deg % 360;
    return d < 0 ? d + 360 : d;
  }
}