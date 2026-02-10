# Contributing to DataGrout Conduit

Thank you for your interest in contributing to DataGrout Conduit!

## Development Setup

### Python

```bash
cd sdk/python

# Create virtual environment
python -m venv venv
source venv/bin/activate  # or `venv\Scripts\activate` on Windows

# Install in development mode
pip install -e ".[dev]"

# Run tests
pytest

# Format code
black src/
ruff check src/

# Type checking
mypy src/
```

### TypeScript

```bash
cd sdk/typescript

# Install dependencies
npm install

# Build
npm run build

# Run tests
npm test

# Watch mode
npm run dev

# Lint
npm run lint

# Format
npm run format
```

## Project Structure

```
sdk/
├── python/
│   ├── src/datagrout/conduit/
│   │   ├── client.py          # Main client
│   │   ├── types.py           # Type definitions
│   │   └── transports/        # Transport implementations
│   ├── examples/              # Usage examples
│   ├── tests/                 # Test suite
│   └── pyproject.toml
├── typescript/
│   ├── src/
│   │   ├── client.ts          # Main client
│   │   ├── types.ts           # Type definitions
│   │   └── transports/        # Transport implementations
│   ├── examples/              # Usage examples
│   ├── tests/                 # Test suite
│   └── package.json
└── docs/                      # Shared documentation
```

## Making Changes

1. **Fork the repository**

2. **Create a feature branch**
   ```bash
   git checkout -b feature/your-feature-name
   ```

3. **Make your changes**
   - Write clean, idiomatic code for the target language
   - Add tests for new functionality
   - Update documentation as needed
   - Keep Python and TypeScript implementations in sync

4. **Test your changes**
   ```bash
   # Python
   pytest
   
   # TypeScript
   npm test
   ```

5. **Commit your changes**
   ```bash
   git commit -m "feat: add feature description"
   ```
   
   We follow [Conventional Commits](https://www.conventionalcommits.org/):
   - `feat:` - New feature
   - `fix:` - Bug fix
   - `docs:` - Documentation only
   - `style:` - Code style changes (formatting, etc.)
   - `refactor:` - Code refactoring
   - `test:` - Adding or updating tests
   - `chore:` - Maintenance tasks

6. **Push to your fork**
   ```bash
   git push origin feature/your-feature-name
   ```

7. **Open a Pull Request**

## Code Style

### Python

- Follow PEP 8
- Use `black` for formatting (line length: 100)
- Use `ruff` for linting
- Use `mypy` for type checking
- Write docstrings for public APIs

### TypeScript

- Follow TypeScript best practices
- Use Prettier for formatting
- Use ESLint for linting
- Write JSDoc comments for public APIs

## Testing

### Python

```python
# tests/test_client.py
import pytest
from datagrout.conduit import Client

@pytest.mark.asyncio
async def test_client_initialization():
    client = Client("https://gateway.datagrout.ai/servers/test/mcp")
    assert client.url == "https://gateway.datagrout.ai/servers/test/mcp"
```

### TypeScript

```typescript
// tests/client.test.ts
import { describe, it, expect } from 'vitest';
import { Client } from '../src/client';

describe('Client', () => {
  it('should initialize with URL', () => {
    const client = new Client('https://gateway.datagrout.ai/servers/test/mcp');
    expect(client).toBeDefined();
  });
});
```

## Documentation

When adding new features:

1. Update the main README
2. Update API.md with new methods
3. Add examples to the examples/ directory
4. Update CONCEPTS.md if introducing new concepts

## Language Parity

Both Python and TypeScript SDKs should have:

- Same API surface (method names may differ due to conventions)
- Same functionality
- Equivalent examples
- Similar test coverage

## Release Process

1. Update version in `pyproject.toml` and `package.json`
2. Update CHANGELOG.md
3. Create a git tag: `git tag v0.x.0`
4. Push tag: `git push origin v0.x.0`
5. GitHub Actions will automatically publish to PyPI and npm

## Questions?

- Open an issue for discussion
- Join our Discord
- Email: hello@datagrout.ai

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
