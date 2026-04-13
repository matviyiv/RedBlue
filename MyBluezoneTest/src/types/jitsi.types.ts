// jitsi.types.ts — Blue zone contract for the video conferencing service layer
// Contains: room config shapes, participant info, service function signatures
// Does NOT contain: server hostnames, room URLs, ICE/TURN credentials
// Implementation lives in src/services/jitsiService.ts (red zone — not visible in this workspace)

export interface JitsiRoomOptions {
  roomName: string;
  userDisplayName?: string;
  audioMuted?: boolean;
  videoMuted?: boolean;
}

export interface JitsiParticipant {
  participantId: string;
  displayName: string;
  isAudioMuted: boolean;
  isVideoMuted: boolean;
}

export interface JitsiRoomState {
  isConnected: boolean;
  participants: JitsiParticipant[];
  localParticipantId: string | null;
}

// Function signature contract — the concrete implementation lives in the red zone.
// Accept this interface as a prop or via context; do not import the implementation directly.
export interface IJitsiService {
  joinRoom(options: JitsiRoomOptions): Promise<void>;
  leaveRoom(): Promise<void>;
  toggleAudio(): void;
  toggleVideo(): void;
}
