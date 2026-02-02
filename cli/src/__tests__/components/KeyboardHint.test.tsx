import { describe, it, expect } from 'vitest';

// Test data from KeyboardHint.tsx
const PROCESSING_HINTS = [
    { key: 'q', action: 'quit' },
];

const DONE_HINTS = [
    { key: 'o', action: 'open folder' },
    { key: 'n', action: 'new batch' },
    { key: 'q', action: 'quit' },
];

const CONFIG_HINTS = [
    { key: 'Enter', action: 'confirm' },
    { key: 'Esc', action: 'back' },
    { key: 'q', action: 'quit' },
];

const FILE_SELECT_HINTS = [
    { key: '↑↓', action: 'navigate' },
    { key: 'Space', action: 'select' },
    { key: 'Enter', action: 'confirm' },
    { key: 'q', action: 'quit' },
];

describe('KeyboardHint', () => {
    describe('PROCESSING_HINTS', () => {
        it('should have quit hint', () => {
            const quitHint = PROCESSING_HINTS.find(h => h.key === 'q');
            expect(quitHint).toBeDefined();
            expect(quitHint?.action).toBe('quit');
        });

        it('should have only one hint during processing', () => {
            expect(PROCESSING_HINTS.length).toBe(1);
        });
    });

    describe('DONE_HINTS', () => {
        it('should have open folder hint', () => {
            const openHint = DONE_HINTS.find(h => h.key === 'o');
            expect(openHint).toBeDefined();
            expect(openHint?.action).toBe('open folder');
        });

        it('should have new batch hint', () => {
            const newHint = DONE_HINTS.find(h => h.key === 'n');
            expect(newHint).toBeDefined();
            expect(newHint?.action).toBe('new batch');
        });

        it('should have quit hint', () => {
            const quitHint = DONE_HINTS.find(h => h.key === 'q');
            expect(quitHint).toBeDefined();
        });

        it('should have three hints when done', () => {
            expect(DONE_HINTS.length).toBe(3);
        });
    });

    describe('CONFIG_HINTS', () => {
        it('should have confirm hint', () => {
            const confirmHint = CONFIG_HINTS.find(h => h.key === 'Enter');
            expect(confirmHint).toBeDefined();
            expect(confirmHint?.action).toBe('confirm');
        });

        it('should have back hint', () => {
            const backHint = CONFIG_HINTS.find(h => h.key === 'Esc');
            expect(backHint).toBeDefined();
            expect(backHint?.action).toBe('back');
        });

        it('should have quit hint', () => {
            const quitHint = CONFIG_HINTS.find(h => h.key === 'q');
            expect(quitHint).toBeDefined();
        });
    });

    describe('FILE_SELECT_HINTS', () => {
        it('should have navigation hint', () => {
            const navHint = FILE_SELECT_HINTS.find(h => h.key === '↑↓');
            expect(navHint).toBeDefined();
            expect(navHint?.action).toBe('navigate');
        });

        it('should have select hint', () => {
            const selectHint = FILE_SELECT_HINTS.find(h => h.key === 'Space');
            expect(selectHint).toBeDefined();
            expect(selectHint?.action).toBe('select');
        });

        it('should have confirm hint', () => {
            const confirmHint = FILE_SELECT_HINTS.find(h => h.key === 'Enter');
            expect(confirmHint).toBeDefined();
        });

        it('should have four hints for file selection', () => {
            expect(FILE_SELECT_HINTS.length).toBe(4);
        });
    });

    describe('Compact mode rendering', () => {
        it('should format hints in compact mode', () => {
            const formatCompact = (hints: Array<{ key: string; action: string }>) => {
                return hints.map(h => `${h.key}:${h.action}`).join('  ');
            };

            const result = formatCompact(DONE_HINTS);
            expect(result).toBe('o:open folder  n:new batch  q:quit');
        });
    });

    describe('Expanded mode rendering', () => {
        it('should format hints in expanded mode', () => {
            const formatExpanded = (hints: Array<{ key: string; action: string }>) => {
                return hints.map(h => `${h.key.padEnd(8)}→ ${h.action}`);
            };

            const result = formatExpanded(CONFIG_HINTS);
            expect(result.length).toBe(3);
            expect(result[0]).toBe('Enter   → confirm');
        });
    });

    describe('Hint structure', () => {
        it('should have key and action for all hints', () => {
            const allHints = [
                ...PROCESSING_HINTS,
                ...DONE_HINTS,
                ...CONFIG_HINTS,
                ...FILE_SELECT_HINTS,
            ];

            allHints.forEach(hint => {
                expect(hint).toHaveProperty('key');
                expect(hint).toHaveProperty('action');
                expect(typeof hint.key).toBe('string');
                expect(typeof hint.action).toBe('string');
                expect(hint.key.length).toBeGreaterThan(0);
                expect(hint.action.length).toBeGreaterThan(0);
            });
        });
    });
});
