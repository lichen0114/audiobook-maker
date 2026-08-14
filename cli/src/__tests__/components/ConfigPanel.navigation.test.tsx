import React from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from 'ink-testing-library';

import type { FileJob, TTSConfig } from '../../types/profile.js';

let lastSelectProps: any;
let inputHandler: any;

vi.mock('ink', async () => {
    const actual = await vi.importActual<any>('ink');
    return {
        ...actual,
        useInput: (handler: any) => {
            inputHandler = handler;
        },
    };
});

vi.mock('ink-select-input', () => ({
    default: (props: any) => {
        lastSelectProps = props;
        return null;
    },
}));

vi.mock('ink-text-input', () => ({
    default: () => null,
}));

import { ConfigPanel } from '../../components/ConfigPanel.js';

const baseConfig: TTSConfig = {
    voice: 'af_heart',
    speed: 1,
    langCode: 'a',
    chunkChars: 900,
    useMPS: true,
    workers: 1,
    outputDir: null,
    outputFormat: 'mp3',
    bitrate: '192k',
    normalize: false,
    checkpointEnabled: false,
};

const files: FileJob[] = [
    { id: 'job-0', inputPath: '/tmp/book.epub', outputPath: '/tmp/book.mp3', status: 'pending', progress: 0 },
];

function renderPanel(overrides: Partial<{ onConfirm: any; onBack: any }> = {}) {
    const onConfirm = overrides.onConfirm ?? vi.fn();
    const onBack = overrides.onBack ?? vi.fn();
    const result = render(
        <ConfigPanel files={files} config={baseConfig} onConfirm={onConfirm} onBack={onBack} />
    );
    return { ...result, onConfirm, onBack };
}

/** Walks the wizard from the first step to the confirm screen. */
function walkToConfirm() {
    lastSelectProps.onSelect({ value: 'a' });
    lastSelectProps.onSelect({ value: 'af_bella' });
    lastSelectProps.onSelect({ value: '1.0' });
    lastSelectProps.onSelect({ value: 'auto' });
    lastSelectProps.onSelect({ value: 'mp3' });
    lastSelectProps.onSelect({ value: 'continue' });
    lastSelectProps.onSelect({ value: 'off' });
    lastSelectProps.onSelect({ value: 'same' });
}

describe('ConfigPanel (navigation)', () => {
    afterEach(() => {
        cleanup();
        vi.clearAllMocks();
        lastSelectProps = undefined;
        inputHandler = undefined;
    });

    it('toggles normalization without leaving the quality step', () => {
        const { lastFrame } = renderPanel();

        lastSelectProps.onSelect({ value: 'a' });
        lastSelectProps.onSelect({ value: 'af_bella' });
        lastSelectProps.onSelect({ value: '1.0' });
        lastSelectProps.onSelect({ value: 'auto' });
        lastSelectProps.onSelect({ value: 'mp3' });

        expect(lastFrame()).toContain('Select audio quality:');
        lastSelectProps.onSelect({ value: 'normalize' });
        expect(lastFrame()).toContain('Select audio quality:');
        expect(lastFrame()).toContain('Normalized');

        lastSelectProps.onSelect({ value: '320k' });
        expect(lastFrame()).toContain('Checkpointing (resume support):');
    });

    it('keeps both bitrate and normalization in the confirmed config', () => {
        const { onConfirm } = renderPanel();

        lastSelectProps.onSelect({ value: 'a' });
        lastSelectProps.onSelect({ value: 'af_bella' });
        lastSelectProps.onSelect({ value: '1.0' });
        lastSelectProps.onSelect({ value: 'auto' });
        lastSelectProps.onSelect({ value: 'mp3' });
        lastSelectProps.onSelect({ value: 'normalize' });
        lastSelectProps.onSelect({ value: '320k' });
        lastSelectProps.onSelect({ value: 'off' });
        lastSelectProps.onSelect({ value: 'same' });
        lastSelectProps.onSelect({ value: 'start' });

        expect(onConfirm).toHaveBeenCalledWith(
            expect.objectContaining({ bitrate: '320k', normalize: true })
        );
    });

    it('returns to the confirm screen after editing a single setting', () => {
        const { lastFrame } = renderPanel();

        walkToConfirm();
        expect(lastFrame()).toContain('Ready to process!');

        lastSelectProps.onSelect({ value: 'speed' });
        expect(lastFrame()).toContain('Select reading speed:');

        lastSelectProps.onSelect({ value: '1.25' });
        expect(lastFrame()).toContain('Ready to process!');
    });

    it('steps back one screen at a time with ESC', () => {
        const { lastFrame, onBack } = renderPanel();

        lastSelectProps.onSelect({ value: 'a' });
        lastSelectProps.onSelect({ value: 'af_bella' });
        expect(lastFrame()).toContain('Select reading speed:');

        inputHandler('', { escape: true });
        expect(lastFrame()).toContain('Select a voice:');
        inputHandler('', { escape: true });
        expect(lastFrame()).toContain('Select accent:');
        expect(onBack).not.toHaveBeenCalled();

        inputHandler('', { escape: true });
        expect(onBack).toHaveBeenCalledOnce();
    });
});
