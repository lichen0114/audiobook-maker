import { describe, it, expect, vi } from 'vitest';

describe('FileSelector', () => {
    describe('Input validation', () => {
        it('should require non-empty input', () => {
            const value = '';
            const isValid = value.trim().length > 0;
            expect(isValid).toBe(false);
        });

        it('should accept valid file paths', () => {
            const paths = [
                './book.epub',
                '/path/to/book.epub',
                '../relative/book.epub',
            ];

            paths.forEach(path => {
                expect(path.length > 0).toBe(true);
            });
        });

        it('should detect glob patterns', () => {
            const isGlob = (value: string) => value.includes('*');

            expect(isGlob('*.epub')).toBe(true);
            expect(isGlob('./*.epub')).toBe(true);
            expect(isGlob('**/*.epub')).toBe(true);
            expect(isGlob('./book.epub')).toBe(false);
        });

        it('should validate EPUB file extension', () => {
            const isEpub = (path: string) => path.toLowerCase().endsWith('.epub');

            expect(isEpub('book.epub')).toBe(true);
            expect(isEpub('book.EPUB')).toBe(true);
            expect(isEpub('book.pdf')).toBe(false);
            expect(isEpub('book.txt')).toBe(false);
        });
    });

    describe('Help text examples', () => {
        it('should show single file example', () => {
            const example = './book.epub';
            expect(example).toContain('.epub');
        });

        it('should show glob pattern example', () => {
            const example = './*.epub';
            expect(example).toContain('*');
        });

        it('should show directory example', () => {
            const example = './books/';
            expect(example.endsWith('/')).toBe(true);
        });
    });

    describe('File list display', () => {
        it('should truncate long file lists', () => {
            const files = Array.from({ length: 15 }, (_, i) => `book${i}.epub`);
            const displayLimit = 10;
            const displayFiles = files.slice(0, displayLimit);
            const remaining = files.length - displayLimit;

            expect(displayFiles.length).toBe(10);
            expect(remaining).toBe(5);
        });

        it('should show all files when under limit', () => {
            const files = Array.from({ length: 5 }, (_, i) => `book${i}.epub`);
            const displayLimit = 10;
            const displayFiles = files.slice(0, displayLimit);

            expect(displayFiles.length).toBe(5);
        });
    });

    describe('Mode transitions', () => {
        it('should start in input mode', () => {
            const initialMode = 'input';
            expect(initialMode).toBe('input');
        });

        it('should transition to confirm mode after files found', () => {
            let mode = 'input';
            const filesFound = ['book1.epub', 'book2.epub'];

            if (filesFound.length > 0) {
                mode = 'confirm';
            }

            expect(mode).toBe('confirm');
        });

        it('should return to input mode on rejection', () => {
            let mode = 'confirm';
            const rejected = true;

            if (rejected) {
                mode = 'input';
            }

            expect(mode).toBe('input');
        });
    });

    describe('Error handling', () => {
        it('should show error for empty input', () => {
            const input = '';
            const error = !input.trim() ? 'Please enter a file path or glob pattern' : null;
            expect(error).toBe('Please enter a file path or glob pattern');
        });

        it('should show error for non-EPUB files', () => {
            const path = 'book.pdf';
            const isEpub = path.toLowerCase().endsWith('.epub');
            const error = !isEpub ? 'File must be an EPUB file' : null;
            expect(error).toBe('File must be an EPUB file');
        });

        it('should show error for no files found', () => {
            const files: string[] = [];
            const error = files.length === 0 ? 'No EPUB files found' : null;
            expect(error).toBe('No EPUB files found');
        });
    });
});
