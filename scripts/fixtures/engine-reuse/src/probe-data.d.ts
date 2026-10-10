import '@lynx-js/react';

declare module '@lynx-js/react' {
  interface InitData {
    marker: string;
    oldOnly?: string;
  }
  interface GlobalProps {
    probePageId: string;
    marker: string;
    oldOnly?: string;
  }
}

declare global {
  const __ENGINE_REUSE_LAZY_URL__: string;
}
export {};
