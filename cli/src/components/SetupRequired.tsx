import React from 'react';
import { Box, Text, useInput } from 'ink';
import type { PreflightCheck } from '../utils/preflight.js';

interface SetupRequiredProps {
    checks: PreflightCheck[];
    onRetry: () => void;
}

export function SetupRequired({ checks, onRetry }: SetupRequiredProps) {
    useInput((input, key) => {
        if (input === 'r' || input === 'R') {
            onRetry();
        }
    });

    const errors = checks.filter((c) => c.status === 'error');
    const warnings = checks.filter((c) => c.status === 'warning');

    return (
        <Box flexDirection="column" paddingX={2}>
            {/* Header */}
            <Box marginBottom={1}>
                <Text color="yellow" bold>Setup Required</Text>
            </Box>

            {/* Description */}
            <Box marginBottom={1}>
                <Text dimColor>
                    Some dependencies are missing. Please run the setup script first.
                </Text>
            </Box>

            {/* Issues Card */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="red"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Text bold color="red">Issues Found</Text>
                </Box>
                <Box flexDirection="column" paddingLeft={1}>
                    {errors.map((check, i) => (
                        <Box key={i} flexDirection="column" marginBottom={1}>
                            <Box>
                                <Text color="red">✘ </Text>
                                <Text bold>{check.name}: </Text>
                                <Text>{check.message}</Text>
                            </Box>
                            {check.fix && (
                                <Box paddingLeft={2}>
                                    <Text dimColor>Fix: </Text>
                                    <Text color="cyan">{check.fix}</Text>
                                </Box>
                            )}
                        </Box>
                    ))}
                    {warnings.map((check, i) => (
                        <Box key={`w-${i}`} flexDirection="column" marginBottom={1}>
                            <Box>
                                <Text color="yellow">⚠ </Text>
                                <Text bold>{check.name}: </Text>
                                <Text>{check.message}</Text>
                            </Box>
                            {check.fix && (
                                <Box paddingLeft={2}>
                                    <Text dimColor>Fix: </Text>
                                    <Text color="cyan">{check.fix}</Text>
                                </Box>
                            )}
                        </Box>
                    ))}
                </Box>
            </Box>

            {/* Quick Fix Card */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="green"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Text bold color="green">Quick Fix</Text>
                </Box>
                <Box flexDirection="column" paddingLeft={1}>
                    <Box>
                        <Text dimColor>Run this command from the project root:</Text>
                    </Box>
                    <Box marginTop={1}>
                        <Text color="cyan" bold>./setup.sh</Text>
                    </Box>
                    <Box marginTop={1}>
                        <Text dimColor>
                            This will install all required dependencies automatically.
                        </Text>
                    </Box>
                </Box>
            </Box>

            {/* Manual fixes */}
            <Box
                flexDirection="column"
                borderStyle="round"
                borderColor="gray"
                paddingX={2}
                paddingY={1}
                marginBottom={1}
            >
                <Box marginBottom={1}>
                    <Text bold dimColor>Or fix manually:</Text>
                </Box>
                <Box flexDirection="column" paddingLeft={1}>
                    {errors.map((check, i) => (
                        check.fix && (
                            <Box key={i}>
                                <Text dimColor>{check.name}: </Text>
                                <Text color="cyan">{check.fix}</Text>
                            </Box>
                        )
                    ))}
                </Box>
            </Box>

            {/* Retry hint */}
            <Box marginTop={1}>
                <Text dimColor>Press </Text>
                <Text color="cyan" bold>r</Text>
                <Text dimColor> to retry checks after fixing • </Text>
                <Text dimColor>Press </Text>
                <Text color="cyan" bold>q</Text>
                <Text dimColor> to quit</Text>
            </Box>
        </Box>
    );
}
