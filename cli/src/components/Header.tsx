import React from 'react';
import { Box, Text } from 'ink';
import Gradient from 'ink-gradient';

export function Header() {
    const title = `
   ╔═══════════════════════════════════════════════════════════╗
   ║                                                           ║
   ║   🎧  A U D I O B O O K   M A K E R  🎧                   ║
   ║                                                           ║
   ║   ✨ Transform your EPUBs into beautiful audiobooks ✨    ║
   ║                                                           ║
   ╚═══════════════════════════════════════════════════════════╝
`;

    return (
        <Box flexDirection="column" marginBottom={1}>
            <Gradient name="rainbow">
                <Text>{title}</Text>
            </Gradient>
        </Box>
    );
}
