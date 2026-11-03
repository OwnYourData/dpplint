const geo = navigator.geolocation;
export function locate(show) {
  geo.getCurrentPosition(show);
}
