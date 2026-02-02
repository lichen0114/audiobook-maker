import React from 'react';
import { Box, Text } from 'ink';
import Gradient from 'ink-gradient';
import BigText from 'ink-big-text';

export function Header() {
    return (
        <Box flexDirection="column" marginBottom={1} alignItems="center">
            {/* Main Title with 3D Effect */}
            <Gradient name="morning">
                <BigText text="AudioBook" font="chrome" />
            </Gradient>

            {/* Subtitle */}
            <Box marginTop={-1} paddingLeft={1}>
                <Text dimColor>✨ </Text>
                <Text color="cyan">Transform your EPUBs into beautiful audiobooks</Text>
                <Text dimColor> ✨</Text>
            </Box>

            {/* Decorative Line */}
            <Box marginTop={1} paddingLeft={1}>
                <Gradient name="rainbow">
                    <Text>{'─'.repeat(50)}</Text>
                </Gradient>
            </Box>
        </Box>
    );
}
