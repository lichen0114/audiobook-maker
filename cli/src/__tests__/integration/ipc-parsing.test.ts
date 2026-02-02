import { describe, it, expect, vi } from 'vitest';

// Simulates the complete IPC parsing flow from tts-runner.ts
interface ProgressInfo {
    progress: number;
    currentChunk: number;
    totalChunks: number;
    workerStatus?: { id: number; status: string; details: string };
    phase?: string;
    chunkTimingMs?: number;
    heartbeatTs?: number;
    totalChars?: number;
}

// Extracted parsing logic from tts-runner.ts
function parseOutputLine(
    line: string,
    state: {
        lastProgress: number;
        lastCurrentChunk: number;
        lastTotal: number;
        lastPhase?: string;
        lastTotalChars?: number;
    }
): ProgressInfo | null {
    // Parse phase transitions
    if (line.startsWith('PHASE:')) {
        const phase = line.slice(6);
        state.lastPhase = phase;
        return {
            progress: state.lastProgress,
            currentChunk: state.lastCurrentChunk,
            totalChunks: state.lastTotal,
            phase,
            totalChars: state.lastTotalChars,
        };
    }

    // Parse metadata
    if (line.startsWith('METADATA:total_chars:')) {
        const totalChars = parseInt(line.slice(21), 10);
        state.lastTotalChars = totalChars;
        return {
            progress: state.lastProgress,
            currentChunk: state.lastCurrentChunk,
            totalChunks: state.lastTotal,
            phase: state.lastPhase,
            totalChars,
        };
    }

    // Parse per-chunk timing
    if (line.startsWith('TIMING:')) {
        const parts = line.slice(7).split(':');
        if (parts.length >= 2) {
            const chunkTimingMs = parseInt(parts[1], 10);
            return {
                progress: state.lastProgress,
                currentChunk: state.lastCurrentChunk,
                totalChunks: state.lastTotal,
                phase: state.lastPhase,
                chunkTimingMs,
                totalChars: state.lastTotalChars,
            };
        }
    }

    // Parse heartbeat
    if (line.startsWith('HEARTBEAT:')) {
        const heartbeatTs = parseInt(line.slice(10), 10);
        return {
            progress: state.lastProgress,
            currentChunk: state.lastCurrentChunk,
            totalChunks: state.lastTotal,
            phase: state.lastPhase,
            heartbeatTs,
            totalChars: state.lastTotalChars,
        };
    }

    // Parse worker status
    if (line.startsWith('WORKER:')) {
        const parts = line.split(':');
        if (parts.length >= 4) {
            const id = parseInt(parts[1], 10);
            const status = parts[2];
            const details = parts.slice(3).join(':');

            return {
                progress: state.lastProgress,
                currentChunk: state.lastCurrentChunk,
                totalChunks: state.lastTotal,
                phase: state.lastPhase,
                workerStatus: { id, status, details },
                totalChars: state.lastTotalChars,
            };
        }
    }

    // Parse progress
    const chunkMatch = line.match(/(?:PROGRESS:)?(\d+)\/(\d+)\s*chunks/);
    if (chunkMatch) {
        const current = parseInt(chunkMatch[1], 10);
        const total = parseInt(chunkMatch[2], 10);
        const progress = Math.round((current / total) * 100);

        state.lastProgress = progress;
        state.lastCurrentChunk = current;
        state.lastTotal = total;

        return {
            progress,
            currentChunk: current,
            totalChunks: total,
            phase: state.lastPhase,
            totalChars: state.lastTotalChars,
        };
    }

    return null;
}

describe('IPC Parsing Integration', () => {
    describe('Complete processing flow simulation', () => {
        it('should parse a complete processing session', () => {
            const output = `PHASE:PARSING
METADATA:total_chars:15000
Processing 25 chunks (sequential GPU + background encoding)
PHASE:INFERENCE
WORKER:0:INFER:Chunk 1/25
TIMING:0:1234
PROGRESS:1/25 chunks
HEARTBEAT:1704067200000
WORKER:0:INFER:Chunk 2/25
TIMING:1:1156
PROGRESS:2/25 chunks
WORKER:0:INFER:Chunk 3/25
TIMING:2:1089
PROGRESS:3/25 chunks
PHASE:CONCATENATING
Concatenating audio segments...
PHASE:EXPORTING

Done.
Output: book.mp3
Chunks: 25`;

            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            const progressUpdates: ProgressInfo[] = [];
            const lines = output.split('\n');

            for (const line of lines) {
                const update = parseOutputLine(line.trim(), state);
                if (update) {
                    progressUpdates.push(update);
                }
            }

            // Verify we captured the key events
            expect(progressUpdates.length).toBeGreaterThan(0);

            // Check phases
            const phases = progressUpdates
                .filter(u => u.phase)
                .map(u => u.phase);
            expect(phases).toContain('PARSING');
            expect(phases).toContain('INFERENCE');
            expect(phases).toContain('CONCATENATING');
            expect(phases).toContain('EXPORTING');

            // Check metadata
            const metadataUpdate = progressUpdates.find(u => u.totalChars === 15000);
            expect(metadataUpdate).toBeDefined();

            // Check progress updates (PROGRESS lines, but state carries over to other updates too)
            const progressLines = progressUpdates.filter(u =>
                u.progress > 0 && u.currentChunk > 0
            );
            expect(progressLines.length).toBeGreaterThanOrEqual(3);

            // Check timing updates
            const timingUpdates = progressUpdates.filter(u => u.chunkTimingMs !== undefined);
            expect(timingUpdates.length).toBe(3);

            // Check heartbeat
            const heartbeatUpdate = progressUpdates.find(u => u.heartbeatTs !== undefined);
            expect(heartbeatUpdate).toBeDefined();
            expect(heartbeatUpdate?.heartbeatTs).toBe(1704067200000);

            // Check worker status
            const workerUpdates = progressUpdates.filter(u => u.workerStatus !== undefined);
            expect(workerUpdates.length).toBe(3);
            expect(workerUpdates[0].workerStatus?.details).toBe('Chunk 1/25');
        });
    });

    describe('Multi-line buffering', () => {
        it('should handle partial line buffering', () => {
            // Simulate data arriving in chunks (as it would from stdout)
            const chunks = [
                'PHASE:PARS',
                'ING\nMETADATA:total_chars:5000\n',
                'PHASE:INFER',
                'ENCE\nPROGRESS:1/10 chunks\n',
            ];

            let buffer = '';
            const results: ProgressInfo[] = [];
            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            for (const chunk of chunks) {
                buffer += chunk;
                const lines = buffer.split('\n');

                // Keep the last incomplete line in buffer
                buffer = lines.pop() || '';

                for (const line of lines) {
                    const update = parseOutputLine(line.trim(), state);
                    if (update) {
                        results.push(update);
                    }
                }
            }

            // Process any remaining buffer
            if (buffer.trim()) {
                const update = parseOutputLine(buffer.trim(), state);
                if (update) {
                    results.push(update);
                }
            }

            expect(results.length).toBe(4);
            expect(results[0].phase).toBe('PARSING');
            expect(results[1].totalChars).toBe(5000);
            expect(results[2].phase).toBe('INFERENCE');
            expect(results[3].currentChunk).toBe(1);
        });
    });

    describe('State persistence across updates', () => {
        it('should maintain state across updates', () => {
            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            // First update sets phase
            const update1 = parseOutputLine('PHASE:INFERENCE', state);
            expect(update1?.phase).toBe('INFERENCE');

            // Subsequent updates should retain phase
            const update2 = parseOutputLine('TIMING:0:1000', state);
            expect(update2?.phase).toBe('INFERENCE');

            // Progress update should also retain phase
            const update3 = parseOutputLine('PROGRESS:1/10 chunks', state);
            expect(update3?.phase).toBe('INFERENCE');
            expect(update3?.currentChunk).toBe(1);
            expect(update3?.totalChunks).toBe(10);
        });
    });

    describe('Error recovery', () => {
        it('should handle malformed lines gracefully', () => {
            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            // These should not crash
            expect(parseOutputLine('', state)).toBeNull();
            expect(parseOutputLine('random garbage', state)).toBeNull();
            expect(parseOutputLine('PHASE:', state)).not.toBeNull(); // Empty phase
            expect(parseOutputLine('TIMING:', state)).toBeNull(); // Missing data
            expect(parseOutputLine('WORKER:0', state)).toBeNull(); // Incomplete
        });
    });

    describe('Progress calculation accuracy', () => {
        it('should calculate progress percentage correctly', () => {
            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            const testCases = [
                { line: 'PROGRESS:0/100 chunks', expected: 0 },
                { line: 'PROGRESS:25/100 chunks', expected: 25 },
                { line: 'PROGRESS:50/100 chunks', expected: 50 },
                { line: 'PROGRESS:75/100 chunks', expected: 75 },
                { line: 'PROGRESS:100/100 chunks', expected: 100 },
                { line: 'PROGRESS:1/3 chunks', expected: 33 },
                { line: 'PROGRESS:2/3 chunks', expected: 67 },
            ];

            for (const { line, expected } of testCases) {
                const update = parseOutputLine(line, state);
                expect(update?.progress).toBe(expected);
            }
        });
    });

    describe('Worker status parsing', () => {
        it('should parse all worker statuses', () => {
            const state = {
                lastProgress: 0,
                lastCurrentChunk: 0,
                lastTotal: 0,
            };

            const statuses = [
                { line: 'WORKER:0:IDLE:Waiting', id: 0, status: 'IDLE', details: 'Waiting' },
                { line: 'WORKER:0:INFER:Chunk 5/50', id: 0, status: 'INFER', details: 'Chunk 5/50' },
                { line: 'WORKER:1:ENCODE:Processing', id: 1, status: 'ENCODE', details: 'Processing' },
            ];

            for (const { line, id, status, details } of statuses) {
                const update = parseOutputLine(line, state);
                expect(update?.workerStatus?.id).toBe(id);
                expect(update?.workerStatus?.status).toBe(status);
                expect(update?.workerStatus?.details).toBe(details);
            }
        });
    });
});
