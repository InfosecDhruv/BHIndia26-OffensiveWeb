#!/bin/bash

#Example usage: ./getSUIDs.sh https://archive.apache.org/dist/commons/beanutils/binaries/ org.apache.commons.beanutils.BeanComparator
#Example2 usage: ./getSUIDs.sh https://archive.apache.org/dist/commons/collections/binaries/ org.apache.commons.collections4.functors.InvokerTransformer

url=$1
class=$2

mkdir tmpjars
for zip in $(curl -s $url | grep '.zip<' | grep -Eo 'href="[^\"]+"' | cut -d '"' -f 2);do 
	wget -O tmpjars/current.zip -4 $url$zip &>/dev/null
	unzip tmpjars/current.zip -d tmpjars &>/dev/null
	
	echo "Checking file: $zip"
	for jar in $(find tmpjars/ -name '*.jar');do 
		serialver -classpath $jar $class 2>/dev/null| grep serialVersionUID	
	done
	
	rm -rf tmpjars/*
done
rm -d tmpjars/
