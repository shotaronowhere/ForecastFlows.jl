#!/usr/bin/env julia

using ForecastFlows
using JSON3

function main()
    for line in eachline(stdin)
        isempty(strip(line)) && continue
        println(stdout, JSON3.write(ForecastFlows.prediction_market_worker_response(line)))
        flush(stdout)
    end
end

main()
