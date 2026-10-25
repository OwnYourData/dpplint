export async function scan() {
  const stream = await navigator.mediaDevices.getUserMedia({ video: true });
  return stream;
}
