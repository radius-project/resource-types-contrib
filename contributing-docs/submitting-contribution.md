## Contribution Checklist

Before submitting your contribution. Make sure to check the following:

- [ ] Resource type schema follows naming conventions
- [ ] All properties have clear descriptions
- [ ] Required properties are properly marked
- [ ] Read-only properties are marked as `readOnly: true`
- [ ] Recipes are provided for at least one platform
- [ ] Recipes handle secrets securely
- [ ] Recipes include necessary parameters and outputs
- [ ] Recipes are idempotent and can be run multiple times without issues
- [ ] Recipes output necessary connection information
- [ ] Test your resource type and recipes locally
- [ ] Documentation is complete and clear

## Submission Process

1. **Fork** this repository
2. **Create** a feature branch: `git checkout -b feature/my-resource-type`
3. **Add** your resource type definition and recipes
4. **Test** your resource type and recipe thoroughly
5. **Commit** your changes with description of the contribution
6. **Push** to your fork: `git push origin feature/my-resource-type`
7. **Create** a Pull Request with:
   - Clear description of the resource type
   - Usage examples
   - Testing instructions
   - Any special considerations

## Review Process

All contributions will be reviewed by the Radius maintainers and Approvers. The review will focus on:

- Contribution need and relevance 
- Schema correctness and consistency
- Recipe functionality and security
- Documentation completeness
- Test coverage as applicable

Thank you for contributing to the Radius ecosystem!