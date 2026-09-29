const { onRequest } = require("firebase-functions/v2/https");
const { RtcTokenBuilder, RtcRole } = require("agora-access-token");

const APP_ID = process.env.AGORA_APP_ID;
const APP_CERTIFICATE = process.env.AGORA_APP_CERTIFICATE;

exports.getAgoraToken = onRequest(
  {
    region: "asia-southeast1",
    cors: true,
    secrets: ["AGORA_APP_ID", "AGORA_APP_CERTIFICATE"],
  },
  (req, res) => {
    try {
      const channelName = req.query.channel;

      if (!channelName) {
        return res.status(400).json({
          error: "Channel name wajib diisi",
        });
      }

      const uid = Number(req.query.uid || 0);

      const expirationInSeconds = 3600;
      const privilegeExpiredTs =
        Math.floor(Date.now() / 1000) + expirationInSeconds;

      const token = RtcTokenBuilder.buildTokenWithUid(
        APP_ID,
        APP_CERTIFICATE,
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
  }
);
