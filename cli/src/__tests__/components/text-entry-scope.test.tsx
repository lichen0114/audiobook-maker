import React from 'react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { Text, useInput } from 'ink';
import { cleanup, render } from 'ink-testing-library';

import { TextEntryProvider, useIsTextEntryActive } from '../../contexts/text-entry.js';
import { FileSelector } from '../../components/FileSelector.js';

/** Mirrors how App.tsx gates its single-letter shortcuts. */
function GlobalShortcuts({ onQuit }: { onQuit: () => void }) {
    const textEntryActive = useIsTextEntryActive();

    useInput((input) => {
        if (input === 'q') {
            onQuit();
        }
    }, { isActive: !textEntryActive });

    return <Text> </Text>;
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 20));

describe('text entry scoping', () => {
    afterEach(() => {
        cleanup();
        vi.clearAllMocks();
    });

    it('does not fire the global quit shortcut while a text field is focused', async () => {
        const onQuit = vi.fn();
        const { stdin } = render(
            <TextEntryProvider>
                <GlobalShortcuts onQuit={onQuit} />
                <FileSelector onFilesSelected={() => {}} />
            </TextEntryProvider>
        );

        await flush();
        stdin.write('q');
        await flush();

        expect(onQuit).not.toHaveBeenCalled();
    });

    it('fires the global quit shortcut when no text field is focused', async () => {
        const onQuit = vi.fn();
        const { stdin } = render(
            <TextEntryProvider>
                <GlobalShortcuts onQuit={onQuit} />
            </TextEntryProvider>
        );

        await flush();
        stdin.write('q');
        await flush();

        expect(onQuit).toHaveBeenCalled();
    });
});
