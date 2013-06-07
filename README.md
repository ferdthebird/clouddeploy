clouddeploy
===========

A ruby script using the gli and fog gems to create and update instance images, launch services and manage databases for multiple runtime environments.  Not my finest example of code because it is extremely large and monolithic, but it does do a lot.  

example usage:  clouddeploy -v launch -x production -i m1.medium -N test_service_prod test_service
