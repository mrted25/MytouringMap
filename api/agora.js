const { RtcTokenBuilder, RtcRole } = require("agora-token");

module.exports = (req, res) => {
  try {
    const channelName = req.query.channel;
    const uid = Number(req.query.uid || 0);

    if (!channelName) {
      return res.status(400).json({
        error: "Channel name wajib diisi",
      });
    }

    const appId = process.env.AGORA_APP_ID;
    const appCertificate = process.env.AGORA_APP_CERTIFICATE;

    if (!appId || !appCertificate) {
      return res.status(500).json({
        error: "Konfigurasi Agora belum tersedia di server",
      });
    }

    const expirationInSeconds = 3600;
    const privilegeExpiredTs =
      Math.floor(Date.now() / 1000) + expirationInSeconds;

    const token = RtcTokenBuilder.buildTokenWithUid(
      appId,
      appCertificate,
      channelName,
      uid,
      RtcRole.PUBLISHER,
      privilegeExpiredTs
    );

    return res.status(200).json({
      token: token,
      channel: channelName,
      uid: uid,
    });
  } catch (error) {
    console.error("Agora token error:", error);

    return res.status(500).json({
      error: "Gagal membuat Agora token",
    });
  }
};
