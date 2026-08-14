import React from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { cleanup, render } from 'ink-testing-library';

import type { BatchJobPlan, FileJob, TTSConfig } from '../../types/profile.js';

const exit = vi.fn();
let inputHandler: any;

vi.mock('ink', async () => {
    const actual = await vi.importActual<any>('ink');
    return {
        ...actual,
        useApp: () => ({ exit }),
        useInput: (handler: any) => {
            inputHandler = handler;
        },
    };
});

vi.mock('ink-gradient', () => ({
    default: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));

vi.mock('../../components/GpuMonitor.js', () => ({
    GpuMonitor: () => null,
}));

vi.mock('../../utils/tts-runner.js', () => ({
    runTTS: vi.fn(() => new Promise(() => {})),
}));

vi.mock('../../utils/checkpoint.js', () => ({
    deleteCheckpoint: vi.fn(() => Promise.resolve()),
}));

import { BatchProgress } from '../../components/BatchProgress.js';

const config: TTSConfig = {
    voice: 'af_heart',
    speed: 1,
    langCode: 'a',
    chunkChars: 900,
    useMPS: true,
    workers: 1,
    outputDir: null,
    outputFormat: 'mp3',
};

const files: FileJob[] = [
    { id: 'job-0', inputPath: '/tmp/book.epub', outputPath: '/tmp/book.mp3', status: 'processing', progress: 10 },
];

const jobPlans: BatchJobPlan[] = [
    {
        id: 'job-0',
        inputPath: '/tmp/book.epub',
        outputPath: '/tmp/book.mp3',
        format: 'mp3',
        config,
        metadata: { title: 'book', author: 'Unknown Author', hasCover: false },
        checkpoint: { exists: false, resumeCompatible: false, action: 'ignore' },
        estimate: { totalChars: 1000, totalChunks: 10, chapterCount: 1 },
        warnings: [],
        errors: [],
    },
];

function renderProgress() {
    return render(
        <BatchProgress files={files} setFiles={vi.fn()} jobPlans={jobPlans} onComplete={vi.fn()} />
    );
}

describe('BatchProgress (quit confirmation)', () => {
    afterEach(() => {
        cleanup();
        vi.clearAllMocks();
        inputHandler = undefined;
    });

    it('asks for confirmation instead of quitting immediately on q', () => {
        const { lastFrame } = renderProgress();

        inputHandler('q', {});

        expect(exit).not.toHaveBeenCalled();
        expect(lastFrame()).toContain('Quit now?');
    });

    it('quits after confirming and resumes after declining', () => {
        const { lastFrame } = renderProgress();

        inputHandler('q', {});
        inputHandler('n', {});
        expect(lastFrame()).not.toContain('Quit now?');
        expect(exit).not.toHaveBeenCalled();

        inputHandler('q', {});
        inputHandler('y', {});
        expect(exit).toHaveBeenCalledOnce();
    });

    it('always quits on Ctrl+C', () => {
        renderProgress();

        inputHandler('c', { ctrl: true });

        expect(exit).toHaveBeenCalledOnce();
    });
});
