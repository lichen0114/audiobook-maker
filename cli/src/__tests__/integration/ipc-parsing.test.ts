import { describe, it, expect } from 'vitest';
import { createParserState, parseOutputLine, type ProgressInfo } from '../../utils/tts-runner.js';

describe('IPC parsing integration', () => {
    it('parses a complete processing flow with state carried across events', () => {
        const output = `PHASE:PARSING
METADATA:backend_resolved:mock
METADATA:total_chars:15000
METADATA:chapter_count:5
PHASE:INFERENCE
WORKER:0:INFER:Chunk 1/25
TIMING:0:1234
PROGRESS:1/25 chunks
HEARTBEAT:1704067200000
WORKER:0:INFER:Chunk 2/25
TIMING:1:1156
PROGRESS:2/25 chunks
PHASE:CONCATENATING
PHASE:EXPORTING`;

        const state = createParserState();
        const updates: ProgressInfo[] = [];

        for (const line of output.split('\n')) {
            const parsed = parseOutputLine(line, state);
            if (parsed) {
                updates.push(parsed);
            }
        }

        expect(updates.length).toBeGreaterThan(0);

        const phases = updates.filter((u) => u.phase).map((u) => u.phase);
        expect(phases).toContain('PARSING');
        expect(phases).toContain('INFERENCE');
        expect(phases).toContain('CONCATENATING');
        expect(phases).toContain('EXPORTING');

        const totalCharsMetadata = updates.find((u) => u.totalChars === 15000);
        expect(totalCharsMetadata?.backendResolved).toBe('mock');

        const chapterMetadata = updates.find((u) => u.chapterCount === 5);
        expect(chapterMetadata?.chapterCount).toBe(5);

        const timings = updates.filter((u) => u.chunkTimingMs !== undefined);
        expect(timings.length).toBe(2);

        const workers = updates.filter((u) => u.workerStatus !== undefined);
        expect(workers.length).toBe(2);

        const heartbeat = updates.find((u) => u.heartbeatTs !== undefined);
        expect(heartbeat?.heartbeatTs).toBe(1704067200000);
    });

    it('handles partial line buffering and only parses complete lines', () => {
        const chunks = [
            'PHASE:PARS',
            'ING\nMETADATA:total_chars:5000\n',
            'PHASE:INFER',
            'ENCE\nPROGRESS:1/10 chunks\n',
        ];

        const state = createParserState();
        const updates: ProgressInfo[] = [];
        let buffer = '';

        for (const chunk of chunks) {
            buffer += chunk;
            const lines = buffer.split('\n');
            buffer = lines.pop() || '';

            for (const line of lines) {
                const parsed = parseOutputLine(line, state);
                if (parsed) {
                    updates.push(parsed);
                }
            }
        }

        if (buffer.trim()) {
            const parsed = parseOutputLine(buffer.trim(), state);
            if (parsed) {
                updates.push(parsed);
            }
        }

        expect(updates.length).toBe(4);
        expect(updates[0].phase).toBe('PARSING');
        expect(updates[1].totalChars).toBe(5000);
        expect(updates[2].phase).toBe('INFERENCE');
        expect(updates[3].currentChunk).toBe(1);
    });

    it('parses JSON IPC flow emitted by backend --event_format json', () => {
        const output = `{"type":"phase","phase":"PARSING"}
{"type":"metadata","key":"backend_resolved","value":"mock"}
{"type":"metadata","key":"total_chars","value":3000}
{"type":"phase","phase":"INFERENCE"}
{"type":"worker","id":0,"status":"INFER","details":"Chunk 1/3"}
{"type":"timing","chunk_timing_ms":456}
{"type":"progress","current_chunk":1,"total_chunks":3}
{"type":"heartbeat","heartbeat_ts":1704067200000}
{"type":"phase","phase":"EXPORTING"}`;

        const state = createParserState();
        const updates: ProgressInfo[] = [];

        for (const line of output.split('\n')) {
            const parsed = parseOutputLine(line, state);
            if (parsed) {
                updates.push(parsed);
            }
        }

        expect(updates.some((u) => u.phase === 'PARSING')).toBe(true);
        expect(updates.some((u) => u.phase === 'INFERENCE')).toBe(true);
        expect(updates.some((u) => u.phase === 'EXPORTING')).toBe(true);
        expect(updates.some((u) => u.backendResolved === 'mock')).toBe(true);
        expect(updates.some((u) => u.totalChars === 3000)).toBe(true);
        expect(updates.some((u) => u.chunkTimingMs === 456)).toBe(true);
        expect(updates.some((u) => u.heartbeatTs === 1704067200000)).toBe(true);
        expect(updates.some((u) => u.currentChunk === 1 && u.totalChunks === 3)).toBe(true);
    });
});
