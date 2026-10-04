export default async function handler(req, res) {
  try {
    const apiKey = process.env.HEIGIT_API_KEY;

    if (!apiKey) {
      return res.status(500).json({
        error: 'HEIGIT_API_KEY belum diset di Vercel',
      });
    }

    const {
      start = '106.827153,-6.175392',
      end = '106.846548,-6.229728',
      profile = 'driving-car',
    } = req.query;

    const response = await fetch(
      `https://api.heigit.org/openrouteservice/v2/directions/${profile}/geojson`,
      {
        method: 'POST',
        headers: {
          'Authorization': apiKey,
          'Content-Type': 'application/json',
          'Accept': 'application/geo+json',
        },
        body: JSON.stringify({
          coordinates: [
            start.split(',').map(Number),
            end.split(',').map(Number),
          ],
        }),
      },
    );

    const data = await response.json();

    return res.status(response.status).json(data);
  } catch (error) {
    console.error('HeiGIT routing error:', error);

    return res.status(500).json({
      error: 'Gagal menghubungi HeiGIT',
      message: error.message,
    });
  }
}
