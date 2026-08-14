import React, { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

interface TextEntryRegistry {
    active: boolean;
    acquire: () => void;
    release: () => void;
}

const TextEntryContext = createContext<TextEntryRegistry>({
    active: false,
    acquire: () => {},
    release: () => {},
});

/**
 * Tracks whether a text field currently owns keyboard input, so global
 * single-letter shortcuts can stand down while the user is typing.
 */
export function TextEntryProvider({ children }: { children: React.ReactNode }) {
    const [count, setCount] = useState(0);

    const acquire = useCallback(() => setCount((value) => value + 1), []);
    const release = useCallback(() => setCount((value) => Math.max(0, value - 1)), []);

    const value = useMemo<TextEntryRegistry>(
        () => ({ active: count > 0, acquire, release }),
        [count, acquire, release],
    );

    return <TextEntryContext.Provider value={value}>{children}</TextEntryContext.Provider>;
}

export function useIsTextEntryActive(): boolean {
    return useContext(TextEntryContext).active;
}

/** Marks a text field as focused for as long as `active` stays true. */
export function useTextEntryFocus(active: boolean): void {
    const { acquire, release } = useContext(TextEntryContext);

    useEffect(() => {
        if (!active) {
            return;
        }
        acquire();
        return release;
    }, [active, acquire, release]);
}
