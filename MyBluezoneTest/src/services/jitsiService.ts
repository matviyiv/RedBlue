// RED ZONE — internal server reference
const JITSI = process.env.JITSI_SERVER;
export const joinRoom = (room: string) => `${JITSI}/${room}`;
