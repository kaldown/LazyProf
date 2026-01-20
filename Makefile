.PHONY: release clean

release:
	@./scripts/build.sh

clean:
	@rm -f *.zip *.tar.gz
	@echo "Cleaned build artifacts"
