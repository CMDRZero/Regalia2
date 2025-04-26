stdtest:
#	make buildexe
	echo "Exe run"
	./tester.exe
#	make buildperf
	echo "Profile"
	make profile

buildexe:
	../zig.exe build-exe src/tester.zig -O ReleaseFast

buildperf:
	../zig.exe build-exe src/tester.zig -O Debug -target x86_64-linux

profile:
	perf record -F max -g ./tester
	perf script > perf/out.perf
	./perf/FlameGraph-master/stackcollapse-perf.pl perf/out.perf > perf/out.folded
	./perf/FlameGraph-master/flamegraph.pl perf/out.folded > perf/flamegraph.svg